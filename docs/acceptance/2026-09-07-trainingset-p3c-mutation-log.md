# 切片一 P3c · 变异验证逐条记录

**分支** `feat/trainingset-p3c-version-bump`
**日期** 2026-09-07
**基线** 全套 `1399 passed / 0 failed / 0 skipped`（这一片开工之前）

## 为什么要做变异验证

一条自动检查显示「通过」，本身**说明不了任何事**。举个极端例子：一条检查如果写成「只要程序还在运行就算通过」，那不管代码改成什么样，它永远显示「通过」——这种检查等于没有。

所以，每写完一条新检查，光看它「现在是绿的」不够，还要反过来问一句：**如果我故意把它该抓的那个问题重新制造一次，它会不会真的报错？** 这份文档记的就是这件事——对这一片新增的每一条检查，逐一「故意改坏一处、看它红不红」，一共做了 **10 组**实测。

**纪律**（这类操作本仓之前踩过坑，这次照下面的规矩来）：

- 一组只改一处；改之前先用 `cp` 复制一份备份，改完验证完，用 `cp` 把备份原样拷回去——⛔ 不用 `git checkout <文件>`，因为那个命令会把当时还没提交的其它合法改动也一起冲掉。
- 改 Python（后端用的编程语言）文件前后各清一次「字节码缓存」（一种 Python 为了跑得快留下的临时文件，如果不清，代码明明改了、缓存却还是旧的，会让检查结果失真）。
- 改动之前先确认「锚点」（要改的那句话）在文件里**恰好出现 1 次**——如果出现 0 次或者出现了好几次，说明找错地方了，当场停下、不动文件。
- 每组做完，单独跑一遍 `git status --short`（列出当前有哪些文件跟上一次提交不一样），确认改动**已经**被完整地还原干净，没有残留。

## 编号为什么是 M1–M4、M4b、M5–M9（不是连续的 M1–M10）

这份记录一共 10 组，但编号里有一个 **M4b**，不是顺着数下去的 M5。原因如下：

1. **M1–M4** 由做「Task 2」（治理台账训练组那一行的订正）的实施子代理跑出来，记在 `task-2-report.md` 里。
2. 这份材料评审完之后，**控制者**（负责统筹这一整片工作的人）又额外补跑了一组变异——把「训练组那一行」再抄一份，看检查会不会发现「多了一份」。这一组在控制者当时的记录里，编号写的是 **M5**。
3. 但紧接着做「Task 3」（Mac 旧包作废）的那一批变异，**已经**按顺序占用了 M5–M8 这几个编号（材料记在 `task-3-report.md` 里），而且 **M6、M8 这两个编号已经写进了一次正式提交（commit）的说明文字里**（提交号 `e402ed1`），提交记录一旦写下就不能再改。
4. 为了不跟已经写死的 M6、M8 冲突，**把控制者补跑的那一组，事后改名成了 M4b**（意思是「紧跟在 M4 后面、由控制者补做的一组」），而不是重新占用 M5 这个号。

**这段由来必须写清楚**，否则读者看到编号从 M4 跳到 M4b 再到 M5，会以为是记录漏了一组，或者编号弄乱了——实际上 10 组一组不少，只是编号的来历比较绕。

下表汇总每组的由来：

| 组 | 针对 | 素材出处 | 谁跑的 |
|---|---|---|---|
| M1 | 治理台账训练组那一行的值改回 `1` | `task-2-report.md` 第 5 节 | 实施子代理 |
| M2 | 把后端建表代码里的版本号改成 `3` | `task-2-report.md` 第 5 节 | 实施子代理（**控制者复跑确认**） |
| M3 | 只删掉「App 侧仍为 1」那句过渡说明 | `task-2-report.md` 第 5 节 | 实施子代理 |
| M4 | 把训练组那一整行从治理台账里删掉 | `task-2-report.md` 第 5 节 | 实施子代理 |
| **M4b** | 把训练组那一行**再抄一份** | 控制者事后补跑（见下文原样记录） | **控制者** |
| M5 | 把 Mac 旧包那句改写后的新规则**改回原句** | `task-3-report.md` 第 4 节 | **控制者** |
| M6 | 把 Mac 旧包那句改写后的新规则**整行删掉** | `task-3-report.md` 第 4 节 | **控制者** |
| M7 | 删掉「历史记述，非判据」那句说明 | `task-3-report.md` 第 4 节 | **控制者** |
| M8 | 往运维手册里塞一行假的「旧文案」 | `task-3-report.md` 第 4 节 | **控制者** |
| M9 | 把「新规则」和「历史存档说明」**这两行一起删掉** | `task-3-report.md` 第 7 节 | 实施子代理（**控制者复跑确认**） |

---

## 逐组结果

### M1 —— 把治理台账训练组那一行的值改回 `1`

**改了什么**：`docs/governance/m01-schema-versioning-contract.md` 里那一行「训练组 SQLite `PRAGMA user_version`」后面的值，从 `` `2` `` 改回 `` `1` ``（改之前确认这句锚点文字在文件里恰好出现 1 次）。

**跑了什么**：改完之后跑 `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_frozen_contract_texts.py -q`，跑完立刻用备份把文件还原回去，再跑 `git status --short` 确认还原干净。

**原样贴出的观测输出**：

```
.....F                                                                   [100%]
=================================== FAILURES ===================================
_____________ test_m01_matrix_training_set_row_matches_backend_ddl _____________
...
E       AssertionError: m01 矩阵训练组行写 `1`，而后端 DDL 实际是 `2` —— 文档与代码漂移
E       assert '`1`' == '`2`'
E
E         - `2`
E         + `1`

tests/test_frozen_contract_texts.py:196: AssertionError
=========================== short test summary info ============================
FAILED tests/test_frozen_contract_texts.py::test_m01_matrix_training_set_row_matches_backend_ddl
1 failed, 5 passed in 0.19s
```

还原后 `git status --short`：三行，均为本任务当时**尚未提交**的合法改动加一份预先存在、跟本次变异无关的未跟踪文件，另用 `diff` 核实备份与还原后的文件逐字一致（为空）。

**结论**：**1 failed**，失败信息里同时出现 `` `1` `` 和 `` `2` `` 两个数字，说明检查确实发现了「文档写的值」和「代码里的值」不一致。还原干净。符合预期。

---

### M2 —— ⭐ 把后端建表代码里的版本号改成 `3`

**改了什么**：`backend/sql/training_set_schema_v1.sql` 里 `PRAGMA user_version = 2;` 这一句，改成 `PRAGMA user_version = 3;`（一个从未出现过的数字，改之前确认锚点恰好出现 1 次）。

**跑了什么**：同上，跑 `tests/test_frozen_contract_texts.py -q`，跑完还原、核对 `git status --short`。

**原样贴出的观测输出**：

```
....FF                                                                   [100%]
=================================== FAILURES ===================================
____________ test_backend_production_side_is_already_generation_two ____________
...
E       AssertionError: assert 'PRAGMA user_version = 2;' in '...PRAGMA user_version=2 标识版本\n...'

tests/test_frozen_contract_texts.py:167: AssertionError
_____________ test_m01_matrix_training_set_row_matches_backend_ddl _____________
...
    cells = [c.strip() for c in rows[0].strip("|").split("|")]
>       assert cells[1] == f"`{ddl_version}`", (
            f"m01 矩阵训练组行写 {cells[1]}，而后端 DDL 实际是 `{ddl_version}` —— 文档与代码漂移")
E       AssertionError: m01 矩阵训练组行写 `2`，而后端 DDL 实际是 `3` —— 文档与代码漂移
E       assert '`2`' == '`3`'
E
E         - `3`
E         + `2`

tests/test_frozen_contract_texts.py:196: AssertionError
=========================== short test summary info ============================
FAILED tests/test_frozen_contract_texts.py::test_backend_production_side_is_already_generation_two
FAILED tests/test_frozen_contract_texts.py::test_m01_matrix_training_set_row_matches_backend_ddl
2 failed, 4 passed in 0.16s
```

还原后 `git status --short`：三行（同 M1 性质，另用 `diff` 核实建表文件逐字还原、不在改动列表里出现）。

**结论**：**2 failed**（本条新检查 + 上一片 P3a 已有的另一条检查）。本条检查的错误信息里**原样出现「而后端 DDL 实际是 `3`」**——这证明这道检查**真的是每次去读代码里当下写的值**，而不是把「2」这个数字写死在检查代码里、自己骗自己。这是判断这道检查是否靠谱的**最关键**的一次实测，通过。还原干净。

---

### M3 —— 只删过渡态标注

**改了什么**：从治理台账那一行里，删掉子串「（⚠️ 2026-09 切片一起：产物已第 2 代、**App 侧仍为 1**，直到切片二落地）」，其余不动（改之前确认锚点恰好出现 1 次）。

**跑了什么**：同上。

**原样贴出的观测输出**：

```
.....F                                                                   [100%]
=================================== FAILURES ===================================
_____________ test_m01_matrix_training_set_row_matches_backend_ddl _____________
...
>       assert _TRANSITION_NOTE in rows[0], (
            "m01 训练组行改了值但**没带过渡态标注** —— 治理矩阵会声称「训练组已第 2 代」而不说"
            "App 读取端仍是 1，谁照它去写读取端就会越过切片次序")
E       AssertionError: m01 训练组行改了值但**没带过渡态标注** —— 治理矩阵会声称「训练组已第 2 代」而不说App 读取端仍是 1，谁照它去写读取端就会越过切片次序
E       assert '⚠️ 2026-09 切片一起：产物已第 2 代、**App 侧仍为 1**，直到切片二落地' in '| 训练组 SQLite `PRAGMA user_version` | `2` | 训练组 schema **结构变更，或字段语义变更导致新旧产物互不可读**；联动顶层 |'

tests/test_frozen_contract_texts.py:199: AssertionError
=========================== short test summary info ============================
FAILED tests/test_frozen_contract_texts.py::test_m01_matrix_training_set_row_matches_backend_ddl
1 failed, 5 passed in 0.17s
```

还原后 `git status --short`：三行（同 M1 性质），`diff` 核实为空。

**结论**：**1 failed**，失败信息里明确写着「没带过渡态标注」。说明检查不光比对数字，还会盯着「App 侧还没跟上」这句提醒有没有被顺手删掉。符合预期。

---

### M4 —— 把训练组行整行删掉

**改了什么**：把以「| 训练组 SQLite `PRAGMA user_version`」开头的那一整行，从治理台账文件里删掉（改之前确认锚点恰好出现 1 次）。

**跑了什么**：同上。

**原样贴出的观测输出**：

```
.....F                                                                   [100%]
=================================== FAILURES ===================================
_____________ test_m01_matrix_training_set_row_matches_backend_ddl _____________
...
        rows = [l for l in M01.read_text(encoding="utf-8").splitlines()
                if l.startswith("|") and "训练组 SQLite `PRAGMA user_version`" in l]
>       assert len(rows) == 1, (
            f"m01 矩阵里训练组行应恰好 1 行，实测 {len(rows)} 行 —— "
            f"0 行 = 被整行删掉（删证据不是订正）；>1 行 = 又抄了一份")
E       AssertionError: m01 矩阵里训练组行应恰好 1 行，实测 0 行 —— 0 行 = 被整行删掉（删证据不是订正）；>1 行 = 又抄了一份
E       assert 0 == 1
E        +  where 0 = len([])

tests/test_frozen_contract_texts.py:191: AssertionError
=========================== short test summary info ============================
FAILED tests/test_frozen_contract_texts.py::test_m01_matrix_training_set_row_matches_backend_ddl
1 failed, 5 passed in 0.18s
```

还原后 `git status --short`：三行（同 M1 性质），`diff` 核实为空。

**结论**：**1 failed**，失败信息写着「应恰好 1 行，实测 0 行」。说明「把这一行整个删掉」这种蒙混手法（既不承认写错、也不承认没做）会被当场抓到。符合预期。

---

### M4b —— 把训练组行再抄一份（控制者补跑，编号由来见上文）

**改了什么**：把治理台账里训练组那一行，**再复制一份**，让文件里出现两份一模一样的该行（相当于「有人手滑多贴了一次」）。

**跑了什么**：跑 `tests/test_frozen_contract_texts.py`（只跑跟本条相关的那个检查函数），跑完还原、核对 `git status --short` 与该行行数。

**原样贴出的观测输出**（这是控制者当时脚本打印的原文，其中「M5」是当时脚本使用的旧编号，后来按上文说明的原因改名为 M4b，输出内容原样保留、不做改写）：

```
M5 变异已施加：训练组行抄成 2 份        ← 注：这是当时脚本的打印，编号后来改为 M4b
            f"m01 矩阵里训练组行应恰好 1 行，实测 {len(rows)} 行 —— "
E       AssertionError: m01 矩阵里训练组行应恰好 1 行，实测 2 行 —— 0 行 = 被整行删掉（删证据不是订正）；>1 行 = 又抄了一份
1 failed, 5 passed in 0.20s
--- 还原后 git status ---
?? docs/superpowers/plans/2026-09-07-trainingset-p3c-version-bump.md
--- 还原后该行数 ---
1
```

**结论**：**1 failed**，失败信息写着「实测 2 行」，说明检查不但能发现「删了」，也能发现「重复抄了一份」。还原后再数一次该行数量，结果是 `1`（恢复正常），且 `git status` 里只剩一份跟本次变异无关、本来就存在的未跟踪计划文件，没有本次变异的残留。符合预期。

---

### M5 —— 把 Mac 旧包那句改写后的新规则改回原句

**改了什么**：`docs/superpowers/specs/2026-08-14-qmt-nas-deployment-design.md:138` 那一句，从改写后的新规则（「P7 的 zip 只能从 NAS handoff 目录取……」）改回改写之前的原句（「P7 的 zip 既可从 Mac scp，也可直接用 NAS 上那份」）。

**跑了什么**：跑 `cd backend && $PY -m pytest tests/test_deployment_source_texts.py -q`，跑完还原、核对 `git status --short`。

**原样贴出的观测输出**：

```
E       AssertionError: 作用域内仍有「P7 既可从 Mac scp」这类文案 —— P4 重建后照它拷一次就会把 v1 包盖回部署目录，而收口闸全绿：
E       AssertionError: 部署设计里「P7 只能从 NAS handoff 取 / Mac 副本仅作 v1 审计归档 / 不得再 scp 到部署目录」应恰好 1 行，实测 0 行 —— 0 行 = 被整行删掉；>1 行 = 抄了两份（会各自漂移）
2 failed in 0.02s
```

还原后 `git status --short`：只剩本任务当时的 1 个已改文件加 2 个未跟踪文件，无本次变异残留。

**结论**：**2 failed**——「不许出现旧文案」的禁令检查和「必须出现新规则」的正向对照检查**同时**报错，因为改回原句相当于「旧文案回来了、新规则也不见了」，两件坏事一起发生，两条检查各自都抓到了。符合预期。

---

### M6 —— ⭐ 把 Mac 旧包那句改写后的新规则整行删掉

**改了什么**：把 `:138` 那一整行（改写后的新规则）从文件里删掉，跟 M5 不同的是这次**不是改回原句**，而是**整行都不留**。

**跑了什么**：同上。

**原样贴出的观测输出**：

```
tests/test_deployment_source_texts.py::test_p7_source_wording_no_longer_offers_the_mac_copy PASSED [ 50%]
tests/test_deployment_source_texts.py::test_rewritten_p7_source_rule_and_archive_note_are_present FAILED [100%]
E       AssertionError: 部署设计里「…」应恰好 1 行，实测 0 行 —— 0 行 = 被整行删掉；>1 行 = 抄了两份（会各自漂移）
========================= 1 failed, 1 passed in 0.02s ==========================
```

还原后核对：`diff` 与备份逐字一致。

**结论**：**1 failed, 1 passed**——「不许出现旧文案」的禁令检查**变绿了**（因为那句旧文案确实也没了），只有「必须出现新规则」的正向对照检查报了错。这是这份记录里**最关键**的一次实测：它证明**光靠「不许说旧话」这一道检查是不够的**——如果只有这一道，「把整行连证据一起删掉」这种做法能**蒙混过关**（检查显示全绿，但实际上「新规则应该写着的那句话」根本不在文档里了）。必须同时有「新规则必须真的写着」这第二道检查，才能防住这个漏洞。

---

### M7 —— 删掉 `:135` 的「历史记述，非判据」标注

**改了什么**：删掉 Mac 三个旧压缩包那一行末尾「（⚠️ **历史记述，非判据** —— 2026-09 切片一起这三个包已作废为 v1 审计归档，见本表下方那行订正）」这句说明。

**跑了什么**：同上。

**原样贴出的观测输出**：

```
E       AssertionError: Mac 三个 zip 那行应带「历史记述，非判据」标注且恰好 1 行，实测 0 行 —— 少了它，P4 重建之后有人会拿那三个 v1 指纹当「应该是多少」的判据
========================= 1 failed, 1 passed in 0.02s ==========================
```

还原后核对：`diff` 与备份逐字一致。

**结论**：**1 failed**，失败信息明确写着「历史记述，非判据」标注缺失，说明这道检查确实在盯着这句提醒有没有被删掉。符合预期。

---

### M8 —— ⭐ 往运维手册塞一行假违例

**改了什么**：没有动前面那份设计文档，而是往另一份运维操作手册 `docs/runbooks/2026-08-24-qmt-nas-deployment.md` 的**末尾**，追加了一行假的旧文案：`<!-- 变异 M8 临时行：P7 的 zip 既可从 Mac scp -->`。

**跑了什么**：同上。

**原样贴出的观测输出**：

```
tests/test_deployment_source_texts.py::test_p7_source_wording_no_longer_offers_the_mac_copy FAILED [ 50%]
E         docs/runbooks/2026-08-24-qmt-nas-deployment.md:951: <!-- 变异 M8 临时行：P7 的 zip 既可从 Mac scp -->
E       assert not ['docs/runbooks/2026-08-24-qmt-nas-deployment.md:951: <!-- 变异 M8 临时行：P7 的 zip 既可从 Mac scp -->']
========================= 1 failed, 1 passed in 0.02s ==========================
```

还原后核对：`diff` 与备份逐字一致。

**结论**：**1 failed**，而且错误信息**精确点名**了是哪个文件（`docs/runbooks/2026-08-24-qmt-nas-deployment.md`）、第几行（`951`）。这证明这道检查扫描的范围**确实**覆盖了运维手册目录，而不是只盯着一份设计文档——「作用域没有被弄瞎」。符合预期。

---

### M9 —— 那两行一起删（Task 3 修复轮新增，验证「拆成两个检查」是否必要）

这一组是在评审提出「一个检查函数里塞了两条判断，会互相遮住」之后新增的。修复方式是把原来「一个函数里判断两件事」的检查，拆成两个各管一件事的独立检查函数：`test_rewritten_p7_source_rule_is_present`（只管「新规则是否写着」）与 `test_mac_copy_archive_note_is_present`（只管「历史存档说明是否写着」）。

**改了什么**：把「新规则那一行」和「历史存档说明那一行」**这两处一起**从设计文档里删掉（模拟「有人一次性删多了」）。

**跑了什么**：拆分之后先跑一次基线，确认三条检查在干净的树上全部通过；然后施加「两行一起删」的变异，再跑一次同样的检查；跑完还原、核对 `git status --short`。

**基线原样输出（拆分后、变异前，确认三条检查都还是绿的）**：

```
tests/test_deployment_source_texts.py::test_p7_source_wording_no_longer_offers_the_mac_copy PASSED [ 33%]
tests/test_deployment_source_texts.py::test_rewritten_p7_source_rule_is_present PASSED [ 66%]
tests/test_deployment_source_texts.py::test_mac_copy_archive_note_is_present PASSED [100%]

============================== 3 passed in 0.01s ===============================
```

**施加变异后的原样输出**：

```
M9 已施加：两行一起删
```

```
tests/test_deployment_source_texts.py::test_p7_source_wording_no_longer_offers_the_mac_copy PASSED [ 33%]
tests/test_deployment_source_texts.py::test_rewritten_p7_source_rule_is_present FAILED [ 66%]
tests/test_deployment_source_texts.py::test_mac_copy_archive_note_is_present FAILED [100%]

=================================== FAILURES ===================================
___________________ test_rewritten_p7_source_rule_is_present ___________________
...
E       AssertionError: 部署设计里「P7 只能从 NAS handoff 取 / Mac 副本仅作 v1 审计归档 / 不得再 scp 到部署目录」应恰好 1 行，实测 0 行 —— 0 行 = 被整行删掉；>1 行 = 抄了两份（会各自漂移）
E       assert 0 == 1
E        +  where 0 = len([])

tests/test_deployment_source_texts.py:79: AssertionError
____________________ test_mac_copy_archive_note_is_present _____________________
...
E       AssertionError: Mac 三个 zip 那行应带「历史记述，非判据」标注且恰好 1 行，实测 0 行 —— 少了它，P4 重建之后有人会拿那三个 v1 指纹当「应该是多少」的判据
E       assert 0 == 1
E        +  where 0 = len([])

tests/test_deployment_source_texts.py:91: AssertionError
=========================== short test summary info ============================
FAILED tests/test_deployment_source_texts.py::test_rewritten_p7_source_rule_is_present
FAILED tests/test_deployment_source_texts.py::test_mac_copy_archive_note_is_present
========================= 2 failed, 1 passed in 0.02s ==========================
```

还原后的原样输出：

```
M9 还原逐字一致
```

```
$ git status --short
 M backend/tests/test_deployment_source_texts.py
?? docs/superpowers/plans/2026-09-07-trainingset-p3c-version-bump.md
```

（设计文档本身不在变动列表里，说明它已经被完整还原；第二行是本来就存在、跟本次变异无关的未跟踪计划文件；第一行 `M backend/tests/test_deployment_source_texts.py` 是这次「拆分成两个检查函数」这个修复动作**本身**尚未提交的合法改动，不是变异残留。）

**结论**：**2 failed, 1 passed**——两条各自被删掉的内容对应的检查，**各自独立报错、各自点名自己该管的那一处**（一条讲「新规则」缺失，另一条讲「历史存档说明」缺失）。这证明「拆成两个独立的检查函数」确实是必要的：如果当初图省事，把这两条判断写在**同一个**检查函数里，一旦第一条判断先失败，整个函数会立刻停下来，**第二处缺失就会被完全遮住、根本不会被发现**。

---

## 四组最值得看的结论

- **M2** —— 证明那道检查**真的在读代码**，不是拿一个写死的数字自欺欺人：把后端建表代码里的版本号改成从没出现过的 `3`，检查当场报错，而且错误信息里原样写出「实际是 `3`」。
- **M6** —— 证明**光有「不许出现旧文案」是不够的**：把改写后的新规则那一行**整行删掉**，禁令检查反而**变绿了**，只有「新规则必须真的写着」的正向对照检查报了错——这说明「把证据也一起删掉」这种手法能骗过只有一道禁令的检查，正向对照不可省。
- **M8** —— 证明检查的覆盖范围**没有被弄窄或弄瞎**：往一份运维手册里塞一行假的旧文案，检查当场报错，并且精确点名是哪个文件、第几行。
- **M9** —— 证明「拆成两个独立检查」是必要的：把「新规则」和「历史存档说明」这两处**一起**删掉时，拆分后的两条检查**各自**报错、各自点名自己该管的那一处；如果这两条判断合写在同一个检查函数里，第一条判断一失败就会让整个函数停下来，第二处的缺失会被**完全遮住、看不见**。
