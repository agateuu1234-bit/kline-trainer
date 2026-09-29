# 切片一 P4 片 1（重建工具）· 命令行入口 · 非程序员验收清单

**这一片做了什么（一句话）**：把前 5 个任务做好的零件接成一条真正能在终端（黑色/白色的命令输入窗口）里敲的命令，加了好几道「写之前先检查」的关卡（比如不许把文件写进旧数据的存档文件夹、清单文件不许被悄悄覆盖、临时文件夹必须由操作者自己指定），并且规定「每次重建都要偷偷跑两遍、两遍的结果必须逐字节完全一样才算数」——这是保证「以后任何时候都能放心重新跑一次，结果不会变」的唯一保障。

**几个会反复出现的词，先解释一次**：

- **命令行**：在终端里手打（或复制粘贴）一整行文字再按回车，电脑照着这行文字去做事，不是点鼠标。
- **参数**（下面写成 `--dsn`、`--out-dir` 这种带两条短横线的词）：命令行后面跟着的「选项」，告诉程序具体往哪个文件夹写、连哪个数据库等。
- **退出码**：命令跑完之后，电脑内部会记一个数字，`0` 表示「一切正常做完了」，**不是** `0`（比如 `1`、`2`）表示「被程序自己拒绝了、没有做完」。下面很多条验收的「通过判定」就是看这个数字。
- **临时文件夹（本文档里也叫"临时工作根"或 `--scratch-dir`）**：程序运算过程中拿来暂存中间文件的地方，正常情况下运算做完这些中间文件会被清掉。
- **归档 / v1 审计归档**：本机 `~/qmt_trial_out` 这个文件夹，里面存着旧版本产出的训练数据压缩包，规定是**逐字节都不能再改动**——它相当于一份「原始存档」，任何东西都不许写进去。

---

## 开始之前

所有命令都在**这个目录**下跑：

```
/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p4-1/backend
```

命令里那一长串路径 `"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python"` 是电脑上已经装好的 Python（一种编程语言的运行环境）程序，**必须原样照抄**，不能简化成 `python` 或 `python3`。下文用 `$PY` 代表这一长串路径，实际执行时请把 `$PY` 换成这一整串（或者先在终端里执行一次 `PY="/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python"`，之后同一个终端窗口里都可以直接写 `$PY`）。

⚠️ A1、A2、A3、A6、A7 里的命令**每条只有一行**——复制粘贴到终端后如果自动断成了好几行，说明复制过程中被截断了，请重新复制整行。A4、A5、A8 用的是另一种写法（`python -c "..."`，双引号里横跨好几行），这三处请把代码框里的内容**整块一次性复制**（从第一行 `PYTHONDONTWRITEBYTECODE=1...` 一直到最后那个单独的 `"`），粘贴到终端后按一次回车即可，不需要也不应该逐行分开粘贴。

⚠️ 下面凡是要跑 `pytest`（一个专门用来跑自动检查项的工具）的地方，看终端最后几行有没有出现 `passed`、`failed`、`error` 这几个词就够了，不需要看懂中间那一堆 Python 代码堆栈。

---

## A1 · 全套后端自动检查跑一遍，总数对得上、一条都没被跳过

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p4-1/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/ -q -rs
```

**期望看到**：最后一行是 `1676 passed in <一个秒数>`；这个数字实测拆开是「合并前基线 1620 条（在 `origin/main` 一份干净副本上单独跑出来的，未采信任何文档里写的旧数字）+ 本片六个任务新增的 56 条」；输出里**不能**出现 `skipped` 这个词（本仓后端 CI 是 Linux 且零容忍跳过）。

**通过判定**：末行数字恰好是 `1676 passed`，且全文没有 `failed` / `error` / `skipped`。

---

## A2 · 本片新增的这一整份测试文件，逐条 PASS

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p4-1/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_rebuild_training_sets.py -v
```

**期望看到**：实测共 **55 条**，每一条前面都是 `PASSED`；末行 `55 passed`。

⚠️ **这个 55 是实测数字，不是钉死不变的**：其中一组检查（`test_seven_tuple_shape_rejects_each_known_hole`）是「批量」写的——列了一份「已知的残缺样子」清单，以后谁往这份清单里再加一条新的残缺样子，这个数字就会往上涨。所以验收时不要死抠「必须正好是 55」，只要**这一条命令里没有任何一行不是 `PASSED`**、末行没有 `failed`，就算通过。

**通过判定**：全文找不到 `FAILED`，末行形如 `N passed`（`N` ≥ 55）。

---

## A3 · 「不钉死起点会变」与「钉死起点恒定」这一对对照，两条都是绿的

背景：这条命令要防的是一种「悄悄换了一批数据」的隐患——如果程序内部选起点用的是随机数，同一批源数据换个运气就可能选出不一样的起点，产出的训练数据也就跟着变了。下面第一条先证明「不加特殊处理时，这件事真的会发生」，第二条再证明「加了特殊处理之后，起点稳如老狗」。

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p4-1/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_rebuild_training_sets.py::test_unpinned_start_is_not_stable_across_seeds tests/test_rebuild_training_sets.py::test_pinned_start_is_identical_across_seeds -v
```

**期望看到**：两条都是 `PASSED`，末行 `2 passed`。

**通过判定**：两条都 `PASSED`（缺一条都不算通过——只有第二条绿而第一条没跑过，没法证明第二条不是因为"这批测试数据本来就只有一个候选起点"而凑巧一直绿）。

---

## A4 · 亲手看一眼：真的重建一次训练组，发给数据库的每一条指令，逐条都是「只读」

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p4-1/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -c "
import asyncio
from pathlib import Path
import rebuild_training_sets as r
import tests.test_rebuild_training_sets as t
bundle = t.bundle.__wrapped__()
target = t._target_for(bundle)
conn = r.ReadOnlyConn(t._conn(bundle))
import tempfile
with tempfile.TemporaryDirectory() as d:
    asyncio.run(r.rebuild_one(conn, target, Path(d)))
print(f'共 {len(conn.statements)} 条语句：')
[print(f'[{i}] {s}') for i, s in enumerate(conn.statements, 1)]
r.assert_no_write_statements(conn.statements)
print('assert_no_write_statements: 全部通过（没有一条不是 SELECT）')
"
```

**期望看到**：打印出若干条 SQL（数据库查询指令），实测是 7 条；**每一条的开头都是 `SELECT`**（`SELECT` 是"只读、只查询"的意思，与"写入/修改"的 `INSERT`/`UPDATE`/`DELETE` 是两类完全不同的指令）；最后一行是 `assert_no_write_statements: 全部通过（没有一条不是 SELECT）`。

**通过判定**：打印出来的每一行方括号编号后面都以 `SELECT` 开头，且最后一行不是错误信息。

---

## A5 · 用真正的数据库语法解析器，从旧的 SQL 文件里读出三行「旧身份」，指纹和代数都对得上

背景：旧的三份训练数据压缩包各自有一个「指纹」（`content_hash`，8 位字母数字组合，用来确认这份数据没被动过），这三个指纹是**预先钉死**在这份工具的代码里的权威值。这条验收要确认：用真正的数据库语法解析器（不是人手抄、不是简单的文字搜索）从存档 SQL 文件里读出来的三行，指纹与这份权威值一模一样。

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p4-1/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -c "
import rebuild_training_sets as r
from pathlib import Path
rows = r.read_legacy_rows(Path('../docs/runbooks/2026-08-24-qmt-nas-p11-insert-training-sets.sql'))
for row in rows:
    print(row['stock_code'], row['start_datetime'], row['content_hash'], row['schema_version'])
"
```

**期望看到**（顺序可能不同，但这三个指纹必须**都出现**，且每行末尾的代数都是 `1`）：

```
000001.SZ 1756656000 851f9444 1
600519.SH 1762099200 32892a5f 1
000001.SZ 1762099200 150d8d6c 1
```

**通过判定**：三行都出现，指纹分别是 `851f9444` / `32892a5f` / `150d8d6c`，每行最后一个数字都是 `1`（如果这里变成 `2`，说明存档 SQL 文件已经被别的工作动过，要立刻停下来找人核实，⛔ 不能继续往下走）。

---

## A6 · 命令行入口对下面 9 种情况，每一种都要拒绝、退出码不是 0

下面每一行是一条独立的自动检查，命名已经把「拒绝的是什么情况」写在测试名字里了。逐条执行（每行都是一条完整命令，可以整行复制）：

| # | 要防的情况 | 动作（每行整行复制） | 期望看到 |
|---|---|---|---|
| 1 | 产出目录落在归档里 | `cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p4-1/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_rebuild_training_sets.py::test_cli_refuses_out_dir_inside_the_v1_archive -v` | 末行 `1 passed` |
| 2 | 清单指向归档里一个还不存在的路径，且归档目录里一个新文件都不会多出来 | `cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p4-1/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_rebuild_training_sets.py::test_cli_refuses_manifest_inside_the_v1_archive -v` | 末行 `1 passed` |
| 3 | 清单文件已经存在，且已有的旧内容没被覆盖 | `cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p4-1/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_rebuild_training_sets.py::test_cli_refuses_to_overwrite_an_existing_manifest -v` | 末行 `1 passed` |
| 4 | 产出目录已经存在（哪怕是空文件夹） | `cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p4-1/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_rebuild_training_sets.py::test_cli_refuses_an_existing_out_dir -v` | 末行 `1 passed` |
| 5 | `--p11-sql` 与 `--old-snapshot` 都给了、或者都没给 | `cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p4-1/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_rebuild_training_sets.py::test_cli_requires_exactly_one_old_value_source -v` | 末行 `1 passed` |
| 6 | 清单文件在重建进行到一半时被别的东西建了出来（模拟两个人同时操作） | `cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p4-1/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_rebuild_training_sets.py::test_cli_does_not_clobber_a_manifest_created_after_preflight -v` | 末行 `1 passed` |
| 7 | 偷偷跑的两遍重建，字节结果不一致（此时清单文件必须**没有**被建出来） | `cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p4-1/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_rebuild_training_sets.py::test_cli_does_not_publish_when_the_two_rounds_differ -v` | 末行 `1 passed` |
| 8 | `--scratch-dir`（临时工作根）指进了归档，而且全程一次都没有在归档里尝试建过文件 | `cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p4-1/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_rebuild_training_sets.py::test_cli_refuses_a_scratch_dir_inside_the_archive_without_writing_anything -v` | 末行 `1 passed` |
| 9 | `--scratch-dir` 指向一个根本不存在的文件夹 | `cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p4-1/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_rebuild_training_sets.py::test_cli_refuses_a_missing_scratch_dir -v` | 末行 `1 passed` |

**通过判定**：9 行都跑一遍，每一行末尾都是 `1 passed`，没有一行是 `failed`。

⚠️ 第 8 条格外重要：它防的不是「归档里最后多了什么」（因为探针文件会被系统自己建了又删，事后看目录是空的，骗得过「跑完看目录」这种检查），而是「**全程有没有尝试过在归档里创建文件**」这个动作本身，判据是拦在**任何一次尝试创建之前**。

---

## A7 · 两条「正向对照」也要跑一遍，确认它们是绿的

背景：如果只跑上面那一串「拒绝」的检查，一个**逢什么都拒绝**的坏实现（不管你给什么，一律报错）也能让上面 9 条全部通过——那样的话，上面那些检查其实什么都没验证。下面这两条专门确认：**合法**的输入是可以顺利通过的。

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p4-1/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_rebuild_training_sets.py::test_write_gate_accepts_a_normal_target tests/test_rebuild_training_sets.py::test_read_old_snapshot_accepts_a_valid_first_round_manifest -v
```

**期望看到**：两条都是 `PASSED`，末行 `2 passed`。

**通过判定**：两条都 `PASSED`——缺这一条，上面 A6 那 9 条「拒绝」清单本身的判断力就无从证明。

---

## A8 · 亲手确认一次：把清单指向归档里的某个压缩包再跑一遍，那个压缩包的字节数完全没变

⚠️ **这一条与 A6 第 2 行不再是同一件事**（任务评审 Important 发现 1 逼出来的订正）：A6 第 2 行现在验的是「清单指向归档里**还不存在**的路径」——那才是归档边界闸本身在守的场景。这一条验的是**另一条、同样真实的安全保证**：清单指向归档里一个**已经存在**的旧压缩包时，那个包的字节全程不会被动——只是这份保证的**来源**实测证实是 `publish_manifest` 的原子发布（`os.link` 目标已存在即失败，一个字节都不碰），不是归档边界闸本身；归档边界闸删不删，这条包的字节都一样不会变。两条检查合在一起才覆盖了"清单落进归档"这件事的两种子情况（目标存在 / 目标不存在）。这里换一种更直观的方式，让你能亲眼看到「前」和「后」两个数字：

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p4-1/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -c "
import os, tempfile
from pathlib import Path
import rebuild_training_sets as r
with tempfile.TemporaryDirectory() as d:
    d = Path(d)
    os.environ['HOME'] = str(d)
    archive = d / 'qmt_trial_out'
    archive.mkdir()
    victim = archive / '000001.SZ_1756656000.zip'
    victim.write_bytes(b'V1-ORIGINAL-BYTES')
    print('跑之前，包的字节数：', victim.stat().st_size)
    scratch = d / 'scratch'; scratch.mkdir()
    class _StubConn:
        async def close(self): pass
    async def _connect(dsn): return _StubConn()
    r.connect_read_only = _connect
    rc = r.main(['--dsn', 'postgresql://x/y', '--scratch-dir', str(scratch),
                 '--out-dir', str(d / 'out'), '--manifest', str(victim),
                 '--p11-sql', str(Path('..') / 'docs/runbooks/2026-08-24-qmt-nas-p11-insert-training-sets.sql')])
    print('命令的退出码：', rc)
    print('跑完之后，包的字节数：', victim.stat().st_size)
"
```

⚠️ 这条命令用一个**临时文件夹**假扮成 `~/qmt_trial_out`（用 `os.environ['HOME']` 临时改了一下"家目录"这个环境变量，跑完自动还原），不会碰到这台电脑上真正的存档文件夹。

**期望看到**：

```
跑之前，包的字节数： 17
重建中止：...落在 v1 审计归档...之内...⛔ 拒绝写入
命令的退出码： 2
跑完之后，包的字节数： 17
```

**通过判定**：「跑之前」与「跑完之后」两行打印出来的数字**完全相同**（都是 17），命令的退出码不是 0。

---

## 已知残留（本片交付时仍在，⛔ 不在本片修）

以下四条是自查发现、经控制者裁定「本任务不修、交最终整支评审 triage」的已知问题，如实列在这里：

1. **`test_read_legacy_rows_refuses_a_missing_file` 判别力偏弱**：这条检查只确认了"错误信息里带上了那个文件路径"，没有像同组另外两条那样也确认"错误信息里说清楚了失败的理由是什么"。
2. **`read_legacy_rows` 的一处异常捕获范围偏窄**：它只接住了 `OSError`（文件读不出来一类的错误），没有像它的姊妹函数 `read_old_snapshot` 那样同时接住 `ValueError`。这意味着如果 p11 SQL 文件的**文字编码**坏掉（专业说法是 `UnicodeDecodeError`，它属于 `ValueError` 的一种），这个漏洞会让一个没被好好包装过的原始错误直接冒出来，而不是本工具统一使用的、说明清楚的错误提示。
3. **`test_pinned_targets_match_the_authority_row_for_row` 里有两句检查是"摆设"**：这条测试内部先调用了另一个函数，那个函数自己会先抛错——所以这条测试里紧跟着写的那两句判断，在"数据不对"的路径上永远执行不到。这是"重复检查了同一件事"，不是"漏检查了什么"，不影响结果的正确性。
4. **`test_write_detector_reports_nonzero_on_a_planted_write` 用的是循环而不是逐条列出**：这条测试拿一份「坏样本清单」做循环，一旦某一条坏样本提前触发失败，循环会当场停下，清单里排在它后面的样本就不会被跑到——所以理论上后面几个样本有没有问题，这条测试目前**看不出来**。

⛔ 上面四条本任务**没有修**，只是如实记录、原样交给整支的最终评审去定性和排期。

---

## 提示

这份清单的每一条「通过判定」都只需要看终端最后几行出现的字词（`passed`/`failed`/一串数字），不需要读懂中间任何一段 Python 代码。如果某一条的输出与「期望看到」不一致，请把完整的终端输出复制下来，不要自行判断"应该是对的"就跳过。
