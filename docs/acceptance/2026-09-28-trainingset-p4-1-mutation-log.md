# 切片一 P4 片 1（重建工具）· 变异验证逐条记录

**分支** `feat/trainingset-p4-1-rebuild-tool`
**日期** 2026-09-28 / 2026-09-29
**基线**（本文档编写时，`origin/main` 一份干净副本上单独跑出来的实测数字，未采信任何文档里写的旧数字）：`tests/ -q -rs` → **1620 passed / 0 failed / 0 skipped**。

## 为什么要做这件事

一条自动检查显示「通过」，本身**说明不了任何事**——如果一条检查写成「不管发生什么都算通过」，那不管代码改成什么样，它永远是绿的，这种检查等于没有。所以每写完一条新检查，还要反过来问：**如果故意把它该抓的那个问题重新制造一次，它会不会真的报错？** 本文档记的就是这件事：对本片六个任务新增的检查，逐一「故意改坏一处、看它红不红、再复原、确认回绿」。

**纪律**（与本仓其它同类记录一致）：

- 一组只改一处；改之前用 `grep` 记一个「改之前」的计数或那一行的原文，改完再 `grep` 一次核对确实换了新内容，复原后再 `grep` 一次确认回到原样。
- 不用 `git checkout <文件>` 复原（那样会连同其它还没提交的合法改动一起冲掉），改用直接编辑改回去。
- 改 Python 文件前后各清一次「字节码缓存」（`find . -name __pycache__ -type d -exec rm -rf {} +`），否则代码明明改了、Python 内部缓存的旧版本却还在跑，会让结果失真。
- 有多句断言在同一条测试里时，尽量单独 deselect 邻居断言各自证明判别力，不能只看"合跑的汇总"。

⚠️ 本文档不写变异的总条数（这个数字会随后续评审 triage 而漂）；下面按任务分节，逐条记录。

---

## Task 6（本任务新增代码的变异）

Task 6 自己的代码是这一片最后接上的「命令行入口」，覆盖控制者点名的硬约束——每条约束配一组变异，逐组「改坏一处 → 证明落地 → 跑红 → 复原回绿」。

### T6-1 —— 确定性自证被砍成「只跑一遍」

**约束**：确定性自证是无条件的，不能有任何跳过它的开关。

**改了什么**：`main()` 里第二轮重建那 5 行（`mkdtemp` 建新目录 → 路径闸 → 再跑一次 `rebuild_all` → 逐字节比对 → 记录验证目录）整段删掉，直接把第一轮的产出目录当成自己的"验证对象"。

**怎么证明落地**：`grep -c "rebuild-verify-" rebuild_training_sets.py`，改之前 **1**，改之后 **0**。

**红的是哪条**：`test_cli_always_verifies_determinism_even_without_any_flag`（`len(calls) == 2` 断言失败，实际只调了 1 次）**和** `test_cli_does_not_publish_when_the_two_rounds_differ`（两轮字节不一致时理应报非 0 且不发布清单，但因为压根没跑第二轮比对，直接把第一轮结果当成功发布了——`assert 0 != 0` 失败）。两条同时红，说明"无条件确定性自证"这条约束是被这两条测试**合力**守住的，不是只有一条在守。

**复原后是否回绿**：是。改回后 `grep -c "rebuild-verify-"` 回到 1，`pytest tests/test_rebuild_training_sets.py -q -rs` → `55 passed`。

**T6-1b（针对同一条测试里第二句断言单独做的补充变异，⭐ 按本仓"多句断言必须逐句 deselect 单独证明判别力"的规矩）**：上面 T6-1 的改法会让 `len(calls) == 2` 那句先红，`test_cli_always_verifies_determinism_even_without_any_flag` 里紧跟着的 `calls[0] != calls[1]` 那句根本没被执行到——这句本身的判别力没有被单独证明过。于是另做一组更精细的改法：把 `second = Path(tempfile.mkdtemp(prefix="rebuild-verify-", dir=scratch_root))` 改成 `second = out`，但**保留**后面真正调用 `rebuild_all(conn, PINNED_TARGETS, second, old_rows=old_rows)` 那一行（第二轮**仍然真跑**，只是落在跟第一轮同一个目录）。

- **怎么证明落地**：`grep -n "MUTATION-6-1b"` 命中新插入的注释。
- **单独跑**：`pytest tests/test_rebuild_training_sets.py::test_cli_always_verifies_determinism_even_without_any_flag -v`。
- **红的是哪一句**：`len(calls) == 2` 这句**先通过**（确实调了两次），红在**紧跟着**的 `calls[0] != calls[1]`（`assert PosixPath('.../out') != PosixPath('.../out')`）——两个 `PosixPath` 打印出来是同一个路径。这证明了这句断言**自己**（不是靠前一句短路挡住）能抓住"两遍落到同一个目录、逐字节比对恒真"这个退化场景。
- **复原后是否回绿**：是。改回 `mkdtemp(...)` 那一行，`grep -n "MUTATION-6-1b"` 零命中，`pytest tests/test_rebuild_training_sets.py -q -rs` → `55 passed`。

**T6-1c（同一条测试第 4 句断言，同样单独证明）**：`test_cli_always_verifies_determinism_even_without_any_flag` 最后还有一句 `assert json.loads(man.read_text(...))["determinism_verified_against"]`。把实现里 `man["determinism_verified_against"] = str(second)` 那一行的键名故意打错成 `man["determinism_verified"] = str(second)`。

- **怎么证明落地**：`grep -n "MUTATION-6-1c"` 命中新插入的注释；改动前后该变量名 `grep -c "determinism_verified_against"` 从这一行的角度看少了赋值那一处（读取那处仍在测试文件里，计数变化仅体现在实现文件这一行的键名字面量上）。
- **单独跑**：同一条测试单独执行。前三句（`rc == 0`、`len(calls) == 2`、`calls[0] != calls[1]`）**全部通过**，红在第四句：`KeyError: 'determinism_verified_against'`——证明这句断言独立地在守着"清单里必须真的记下验证对象"这件事，不是靠前面三句陪跑。
- **复原后是否回绿**：是。键名改回 `determinism_verified_against`，`grep -n "MUTATION-6-1c"` 零命中，`pytest tests/test_rebuild_training_sets.py -q -rs` → `55 passed`。

### T6-2 —— 清单路径漏挡一个写入目标

**约束**：路径闸必须对每一个写入目标都跑一遍，只挡一个等于没挡。

**改了什么**：删掉 `assert_write_target_is_safe(manifest_path, kind="清单", must_not_exist=True)` 这一行调用。

**怎么证明落地**：`grep -c 'kind="清单"' rebuild_training_sets.py`，改之前 **1**，改之后 **0**。

⚠️ **第 1 轮结论被评审打回，这里是重做后的真相（评审 Important 发现 1）**：第一次做这组变异时，用例里连数据库的替身（`_StubConn`）只有 `close()` 一个方法，闸删掉之后 `main()` 走到 `rebuild_all` → `snapshot_source_counts` 去问一句 `SELECT`，替身没实现 `fetchval`，直接 `AttributeError` 崩出测试之外——两条相关用例确实变成了 pytest 意义上的 `FAILED`，**但那个"红"证明的是"替身不完整"，不是"闸没挡住"**，`main()` 从没机会走到"闸删掉之后到底会不会真的往下写"这一步。

**修法**：补了一个共用替身 `_stub_rebuild_all(monkeypatch)`（写出匹配字节、正常返回），四条相关用例都装上了它，让 `main()` 在闸被删掉之后也能干净走完、返回一个真实的退出码。装好之后重新跑这组变异，**得到两条完全不同的真相**：

1. `test_cli_refuses_to_overwrite_an_existing_manifest`（清单 = `tmp_path/"m.json"`，跑之前已经写好旧内容）：**变异之后仍然是绿的**。追出原因：`main()` 一路走到 `publish_manifest`，它自己的 `os.link(tmp, manifest_path)` 在目标已存在时天然抛 `FileExistsError` → 转成 `RebuildMismatch` → `main()` 返回 1，旧内容全程没被碰。**这条闸删不删，这条用例的结果都一样**——真正兜底的是 `publish_manifest` 的原子发布，不是这里被删掉的预检。这与 `assert_write_target_is_safe` 自己 docstring 里写的"`must_not_exist` 这一支是早失败，不是保证；承重的那道在 `publish_manifest` 的 `os.link`"完全对得上——**属于文档里已经写明的设计性冗余，不是判别力缺陷**，本轮**没有改这条用例**。
2. `test_cli_refuses_manifest_inside_the_v1_archive`（原版：清单指向归档里一个**已经存在**的旧 zip）：**变异之后也仍然是绿的**，原因和上面同一个——`victim` 早就存在，`os.link` 同样会失败，与"清单是否落在归档里"这件事**完全无关**。⇒ 这条用例原来的写法**分不出"归档闸在"与"归档闸不在"**，是一处真实的判别力缺口。**追加实测证实这个缺口是真的**：把 `--manifest` 指向归档里一个**不存在**的路径重新跑一遍原实现（闸删掉），`main()` 返回 **0**（成功！），归档目录里真的多出了一个新文件、**永久留下**（不是探针建了又删）。⇒ **选择方案 (a)：改用例**——`test_cli_refuses_manifest_inside_the_v1_archive` 现在指向归档里一个**不存在**的路径，断言改成"归档目录的文件名集合完全没变"，与 `--scratch-dir` 那条用例是同一个判据形状。重新跑这组变异：`pytest -v` 只针对这条用例，**红**，`assert 0 != 0`——一条干净的断言失败，不再有任何替身崩溃。

**红的是哪条（重做后的最终结论）**：只有（改写后的）`test_cli_refuses_manifest_inside_the_v1_archive` 红，且是干净的 `assert 0 != 0`。`test_cli_refuses_to_overwrite_an_existing_manifest` **仍然是绿的**——如实记录：这条变异对它没有判别力，兜底的是 `publish_manifest` 的原子发布，接受这个事实，未改动该用例。

**复原后是否回绿**：是。`grep -c 'kind="清单"'` 回到 1，`pytest tests/test_rebuild_training_sets.py -q -rs` → `55 passed`。

### T6-3 —— 清单发布退回 `write_text`（丢掉原子性）

**约束**：清单发布必须原子（临时文件 → fsync → `os.link` 不覆盖 → 目录 fsync），预检只是早失败、不是保证。

**改了什么**：`publish_manifest` 里把 `os.link(tmp, manifest_path)` 那一段（含 `except FileExistsError` 分支）整段换成 `Path(manifest_path).write_text(payload, encoding="utf-8")`。

**怎么证明落地**：`grep -n "os.link"` 命中数从改前 **3**（1 处调用 + 2 处 docstring/注释提及）降到改后 **2**（只剩 docstring 提及），且新插入的 `# MUTATION-6-3` 标记行确实出现在文件里。

**红的是哪条**：`test_publish_manifest_refuses_an_existing_destination`（`Failed: DID NOT RAISE`，因为 `write_text` 会直接截断已有文件而不报错）与 `test_cli_does_not_clobber_a_manifest_created_after_preflight`（`assert 0 != 0`，预检早就放行过了，真正的窗口期覆盖没有被拦住）。两条都精确红在预期的断言上，没有旁生崩溃。

**复原后是否回绿**：是。`grep -c "os.link"` 回到 3，`pytest tests/test_rebuild_training_sets.py -q -rs` → `55 passed`。

### T6-4 —— 产出目录的 `os.mkdir` 悄悄放行"已存在"

**约束**：产出目录必须用不加 `exist_ok` 的 `os.mkdir` 原子占位，必须【不存在】。

**改了什么**：`os.mkdir(out)` 的 `except FileExistsError:` 分支从"抛 `RebuildMismatch`"改成 `pass`（悄悄放行）。

**怎么证明落地**：新插入的标记注释 `grep -n` 命中 1 行。

⚠️ **同 T6-2，第 1 轮的"红"也是替身崩溃**（`AttributeError: '_StubConn' object has no attribute 'fetchval'`——同一个成因：`main()` 放行之后走到 `rebuild_all`，撞上不完整的连接替身），补上 `_stub_rebuild_all` 之后重做。

**红的是哪条（重做后）**：`test_cli_refuses_an_existing_out_dir`，`assert 0 != 0`——一条干净的断言失败，`main()` 真的把已存在的目录当成新目录用了、返回 0。这一组**没有**被别的闸兜住：产出目录本身不存在其它保护层，闸一删，违规就直接可见。

**复原后是否回绿**：是。改回抛 `RebuildMismatch` 那一段，`pytest tests/test_rebuild_training_sets.py -q -rs` → `55 passed`。

### T6-5 —— 校验通过后没有把 `tempfile` 钉在已校验的根上

**约束**：这是第 7 轮评审后"塌层"的核心——校验通过后立刻钉死 `tempfile.tempdir`，排在任何分配之前；没有发现逻辑就没有探针写入。

**改了什么**：把 `tempfile.tempdir = str(scratch_root)` 这一行删掉（换成一条注释）。

**怎么证明落地**：`grep -n "tempfile.tempdir = str(scratch_root)"` 改前命中 1 行，改后命中 0 行（换成了 `# MUTATION-6-5` 那一行）。

**红的是哪条**：`test_cli_pins_tempfile_to_the_validated_scratch_root`，且是一条干净的断言失败：`assert None == '<scratch 的真实路径>'`——`seen["tempdir"]` 变成了 `None`，因为没有钉住。

**复原后是否回绿**：是。`grep -n` 确认那一行原样回来，`pytest tests/test_rebuild_training_sets.py -q -rs` → `55 passed`。

### T6-6 —— `--p11-sql` / `--old-snapshot` 的"恰好给一个"检查失效

**约束**：两者必须恰好给一个，不能都给也不能都不给。

**Ruling ⑬：拆成两条独立用例**——原来那条 `test_cli_requires_exactly_one_old_value_source` 把"两者都不给"与"两者都给"两个子场景挤在同一个函数体的两句 `assert` 里，第一句一旦抛出未被接住的裸异常，第二句就永远走不到、它的判别力在正常运行中不可见。这是本片**同一个形状第四次出现**（Task 3 两句断言只有第一句有判别力／Task 5 同一条规矩两份副本只订正一份／Task 6 T6-2 用例被替身崩溃"红"掉／本条），按"同一类缺陷反复出现 ⇒ 修这一类，不是修这一处"的规矩拆开，且拆分本身不是外来结构——计划自己在 Task 5 的 `_HOLES` 就用过 `parametrize` 这种"一份判据、多个独立可见结果"的写法。拆成两条：
- `test_cli_refuses_when_neither_old_value_source_is_given`（子场景 A：两者都不给）
- `test_cli_refuses_when_both_old_value_sources_are_given`（子场景 B：两者都给）

**改了什么**：把 `if bool(args.p11_sql) == bool(args.old_snapshot):` 换成 `if False:`（恒不触发）。

**怎么证明落地**：`grep -n "bool(args.p11_sql) == bool(args.old_snapshot)"` 改前命中该行，改后命中 0。

**红的是哪条（拆开后，两条各自独立跑出的真相）**：

- **子场景 A（两者都不给）**：`pytest ...::test_cli_refuses_when_neither_old_value_source_is_given -v` → **FAILED**，但不是干净的 `assert rc != 0`——检查失效后代码走到 `else read_old_snapshot(Path(args.old_snapshot))`，`args.old_snapshot` 是 `None`，`Path(None)` 直接抛 `TypeError: expected str, bytes or os.PathLike object, not NoneType`，`main()` 只捕 `RebuildMismatch`，这个 `TypeError` 直接穿出去。⚠️ **这次崩溃不是替身不完整造成的**（根本没走到数据库那一步），是移除检查之后代码真实会崩在这里——它是控制者已经裁定"`main()` 只捕 `RebuildMismatch`、其它异常裸抛是计划原文规定、本轮不改"这条**已知残留**在这里的具体表现，⛔ 照实写，不粉饰成"这条也有干净的判别力"。
- **子场景 B（两者都给）**：`pytest ...::test_cli_refuses_when_both_old_value_sources_are_given -v` → **FAILED**，`AssertionError: assert 0 != 0`——检查失效后代码走 `if args.p11_sql:` 分支，`read_legacy_rows` 正常读出真实 p11 SQL、成功返回，`main()` 一路跑完返回 0。**这是一条干净的红**，且拆开之后**在每一次正常的 pytest 运行里都直接可见**——不再需要靠独立脚本才能补验出来（拆分之前，这条子场景的判别力被子场景 A 的裸异常挡住，从未在真实 pytest 运行里出现过）。

两条实测结果与控制者裁决消息里给出的预判**完全吻合**（B 干净、A 崩溃属已知残留），已按实测原样记录，未做任何粉饰或改写。

**复原后是否回绿**：是。改回 `if bool(...) == bool(...):`，`pytest tests/test_rebuild_training_sets.py -q -rs` → `56 passed`（拆分后比之前多 1 条）；随后跑了一次完整 `git diff --stat -- backend/rebuild_training_sets.py`，本任务的各组变异全部复原后与提交前只有本任务的新增内容、没有任何遗留标记（`grep -n "MUTATION"` 两个文件均为 0 命中）。

---

## Task 1–5 的变异证据汇总（材料来自各自的 `task-N-report.md`，本文档只做汇总，不重复整段贴证据）

### Task 1（提取 `load_gating_inputs`）

| 改了什么 | 怎么证明落地 | 红的是哪条 | 复原是否回绿 |
|---|---|---|---|
| 把 `generate_one_training_set` 里对 `load_gating_inputs` 的调用+字段展开，内联抄回提取前的样子（即撤销提取） | `grep -c "load_gating_inputs" generate_training_sets.py`：2 → 1（只剩函数定义，调用点消失） | `test_generate_one_training_set_uses_shared_load_gating_inputs`（`assert [] == ['000001.SZ']`，spy 没被调到） | 是（`105 passed`，覆盖三个相关测试文件，0 skipped） |

### Task 2（起点钉死：`pin_start_excludes` + `build_pinned_windows`）

| 改了什么 | 怎么证明落地 | 红的是哪条 | 复原是否回绿 |
|---|---|---|---|
| `build_pinned_windows` 里 `exclude_starts=excludes` 改成 `exclude_starts=frozenset()`（B55） | `grep -n "exclude_starts="` 读回那一行确认已改 | `test_pinned_start_is_identical_across_seeds`（抛 `RebuildMismatch: 钉死的起点失效`，因为排除集清空后种子 0 没选中目标） | 是（`4 passed`） |

### Task 3（`rebuild_one`：右端权威值断言）

| 改了什么 | 怎么证明落地 | 红的是哪条 | 复原是否回绿 |
|---|---|---|---|
| 5a：删掉右端不符时的整段 `raise RebuildMismatch` | `grep -c "停下来查清楚，不得继续"`：**实测 3→2**（⚠️ brief 原文预告的是「2→1」，与实测不符——原因是 brief 撰写时只数了 `pin_start_excludes` 一处，没算上 `RebuildMismatch` 类自己 docstring 里同一句话；已如实记录，未回改 brief 也未放宽断言，只按实测数字判断"确实改到了"） | `test_rebuild_one_refuses_when_end_datetime_differs_from_authority`（`DID NOT RAISE`） | 是（`6 passed`） |
| 5b：把断言从"装配之前"挪到"装配之后" | `grep -n "result = assemble_from_windows\|return result"` 命中两行（改前不存在） | 同一条测试，但**只红在后半截**——"消息里有没有两个值"那句仍然通过，"磁盘上不该有 zip"那句才失败。证明的是**次序**本身被单独守着 | 是（`6 passed`） |
| 评审加固后再做一次"标签互换"变异（`算出的 end_datetime` 与 `权威值是` 两个标签在错误信息里对调，数值不动） | `grep -n "算出的 end_datetime\|而旧产物的权威值是"` 读回两行确认标签已换 | 同一条测试；**分两轮单独 deselect** 证明两句新断言（`re.search` + 数字边界否定前瞻）各自独立都能抓住这次标签互换，不是靠邻居断言短路挡住的 | 是（两轮 deselect 各自 `1 failed`，复原后 `6 passed`，`git diff` 对实现文件为空） |

### Task 4（源库只读的机器证据）

| 改了什么 | 怎么证明落地 | 红的是哪条 | 复原是否回绿 |
|---|---|---|---|
| 5a：在 `rebuild_one` 结尾加一行裸 `INSERT` | `grep -n "INSERT INTO training_sets"` 命中新加的调用行 | `test_rebuild_one_issues_no_write_statements`（预期项，`assert_no_write_statements` 当场拒绝并点名是哪一条 SQL）；**外加一条 brief 未点名的额外红**：`test_rebuild_one_produces_a_real_zip_with_schema_version_2`（裸 `_FakeConn` 没有 `execute` 方法，是同一处改动的自然副作用，不影响变异有效性） | 是（`11 passed`） |
| 5b：把 `pglast` 真解析换回"首词黑名单"判断（复现 codex 第 4 轮那两个洞） | `grep -c "parse_sql"`：**实测 2→0**（⚠️ brief 原文预告"差 1"，实测差 2，因为 import 行与调用行各含一次 `parse_sql`，两行一起被替换；已如实记录数字不符） | `test_write_detector_reports_nonzero_on_a_planted_write`，且精确红在第 8 个坏样本（`WITH changed AS (UPDATE …) … SELECT …`）——与预期的那两个"首词判断漏掉的洞"逐字吻合 | 是（`11 passed`） |
| 5c：`assert_no_write_statements` 首行插入 `return`（恒放行） | `grep -n "MUTATION 5c"` 命中 1 行 | **分别单独跑两条**：`test_write_detector_reports_nonzero_on_a_planted_write` → 红（`DID NOT RAISE`）；`test_write_detector_passes_on_reads_only` → **仍然是绿的**——这条本身就在演示本仓"假绿家族"头号形态：一套全"拒了"的用例能挑出恒放行的坏判据，但只看正向对照永远绿、单独看不能证明判据没坏，必须两者都做才够 | 是（`11 passed`） |
| 5d：`connect_read_only` 删掉 `server_settings={"default_transaction_read_only": "on"}` | `grep -n "server_settings"` 改后无匹配（改前命中 1 行） | `test_connect_read_only_refuses_a_session_that_is_not_read_only`（替身里"连接时没有要求数据库进入只读"断言当场炸） | 是（`11 passed`，另跑治理守卫 `3 passed`） |

### Task 5（确定性自证 + 新旧两栏清单）

| 改了什么 | 怎么证明落地 | 红的是哪条 | 复原是否回绿 |
|---|---|---|---|
| 5a（B34）：`zip_and_hash` 的 `date_time` 换成随调用次数变化的计数器值 | `grep -n "date_time="` 读回那一行，确认含 `_MUT_N % 60` | `test_two_runs_are_byte_identical`（两次 `content_hash` 不等） | 是（`git diff` 对该文件为空） |
| 5b（B68，**换过对象**——见下方说明）：删掉 `read_legacy_rows` 末尾的代数闸整段 | `grep -c "已经被重新生成过"`：1→0 | `test_read_legacy_rows_refuses_a_regenerated_p11`（`DID NOT RAISE`） | 是（33 条重新绿） |
| 5b 反向：把代数闸硬编码成 `if seen != [2]:` | `grep -n "if seen != \[2\]:"` 命中 | **在当前树（真 p11 SQL，代数确实是 1）上**，`test_legacy_rows_are_parsed_from_the_real_sql_by_a_real_parser` 抛错——证明这道闸不是恒真放行，它确实在读文件里的真实代数 | 是（33 条重新绿） |
| 5c：`read_legacy_rows` 改成忽略输入路径、返回人手写死但数值抄对的三行 | `grep -n "变异 5c"` 命中新加注释行 | **见下方"5c 现有用例没红"专项说明** | 是（`git diff` 与提交前一致） |
| 5d：`PINNED_TARGETS` 第一条 `start_datetime` 末位 +1 | `grep -n "1756656001"` 命中 1 行 | `test_pinned_targets_match_the_authority_row_for_row`（错误信息两边都打出来） | 是（33 条重新绿） |
| 5d 反向：往 `PINNED_TARGETS` 里复制第三条（凑成 4 条重复项） | `grep -n 'RebuildTarget("000001.SZ", 1762099200, 1782835199)'` 命中 2 行 | 同一条测试仍然红，但抓住它的是**长度判据**，不是集合等式本身——`set` 会把重复的元组去重，纯 `pinned == authority` 集合等式**看不出**多了一条 | 是（33 条重新绿） |
| Ruling ⑪ 新增：删掉 `rebuild_all` 里"跑前跑后计数不一致就报错"整段 | `grep -n "if before != after"` 变异后无命中 | **单独跑两条端到端用例**：正向用例仍绿（它本身不依赖这段比对失败）；`test_rebuild_all_refuses_when_source_counts_change_between_before_and_after` 红（`DID NOT RAISE`）——证明只有反向用例能揪出"从不比较"的实现 | 是（33 条重新绿） |
| 评审修复轮：`read_legacy_rows` 三处失败面（读文件 / 解析 / 转整数）的 `try/except` 整段去掉 | `grep -n "读不出来：\|列不是整数"` 计数变成 0 | **三条新用例全部单独 deselect 后各自跑**：`test_read_legacy_rows_refuses_a_missing_file` → `FileNotFoundError` 原始异常直接漏出；`test_read_legacy_rows_refuses_unparsable_sql` → `pglast.parser.ParseError` 原始异常漏出；`test_read_legacy_rows_refuses_a_non_integer_column` → `ValueError` 原始异常漏出。三条**全部**红，且红的理由**都是**"原始异常漏出"，没有一条例外 | 是（`36 passed, 0 skipped`；治理守卫 `3 passed`） |

**5b「换过对象」的说明（按 Task 6 brief 的要求原样交代）**：这条变异原计划打的是"把 `rebuild_all` 里读 P11 那一行挪到重建之后"，用来验证"读旧值必须排在重建之前"这条次序。但 codex 评审第 1 轮之后，`rebuild_all` 的设计已经改成**不再自己读 P11**（旧值改由调用方传进来的 `old_rows` 参数提供，读取与校验的职责挪到了 `read_legacy_rows` / `read_old_snapshot` 各自身上）——原来那条"次序"已经不是这段代码里的承重判据了，继续照原计划打这个补丁等于在测一件已经不存在的事。所以改打真正承重的那一条：`read_legacy_rows` 末尾"P11 是否已被重新生成过"的代数闸。

**5c「现有用例没红」专项说明（按 Task 6 brief 的要求逐条列出，不只记数量）**：

把 `read_legacy_rows` 改成完全忽略输入文件路径、直接返回人手写死（但数值恰好抄对）的三行字面量之后，跑了全套 33 条用例，**逐一核对**结果如下——

1. `test_legacy_rows_are_parsed_from_the_real_sql_by_a_real_parser`：**仍然是绿的**（这是 Task 5 brief 原文就预告过的那一条，预料之中）。
2. `test_pinned_targets_match_the_authority_row_for_row`：**也仍然是绿的**（brief 原文**没有**预告到这一条；是实测时才发现的额外事实——原因是硬编码的三行数值恰好与 `PINNED_TARGETS` 逐一吻合，`pinned == authority` 集合等式与长度判据都凑巧通过）。
3. `test_read_legacy_rows_refuses_a_regenerated_p11`：**红**（`Failed: DID NOT RAISE`）——因为这条用例传入的是一份**变造过**的文件（指纹换新、代数改成 2），而硬编码实现完全不读这份文件，所以"代数变了会被发现"这件事在硬编码版本下必然对不上。

**补救措施**：没有新增测试，也没有回改实现。理由是：第 1、2 两条测试单独看，只能证明"对**当前**这份真实文件返回了正确的值"——一个记性好、抄得准的人手写死也能让它们保持绿色，它们**证明不了**"真的调用了 pglast 去解析文件"这件事。真正能揪出"没有真解析、只是抄了固定值"的，是第 3 条——它换了一份**不同**的输入文件，期望返回值理应跟着变化（并拒绝）。这正是片 2 会触发的真实场景：P11 一旦被重新生成，只有"真解析"才会在那一刻发现代数已经不是 1 了。也就是说，**判别力已经存在于套件里**（由第 3 条提供），第 1、2 两条测试单独的"无判别力"是这份判别力天然的影子，不需要另外补一条新测试去堵它。

---

## 汇总结论

- Task 1–6 六个任务的变异证据里，"故意改坏之后、某条既有测试仍然是绿的"这类情况，逐条列出、不只记数量：Task 4 的 5c（`test_write_detector_passes_on_reads_only` 在恒放行判据下仍绿——"正向对照单独看永远绿"的示范，必须配合反向用例一起看）、Task 5 的 5c（见上方专项说明），以及 Task 6 T6-2 里的 `test_cli_refuses_to_overwrite_an_existing_manifest`（见下方，成因与前两条不同：不是判据本身恒真，而是**另一道独立机制**——`publish_manifest` 的原子发布——按设计兜了底）。⚠️ 前一版这里写的是"唯二"，本轮发现第三个实例后已订正，不再用"唯二"这种会随复核轮数增加而过期的计数措辞。
- 出现"brief 预告的数字与实测不符"的两处（Task 3 的 5a「2→1」实为「3→2」；Task 4 的 5b「差 1」实为「差 2」）都已如实记录，均未回改 brief 原文，也未因此放宽任何断言。
- Task 5 的 5b 属于"按上一轮评审订正换了打击对象"的情况，换的理由与前后对象已在上文写明。
- Task 6 自己各组变异的最终真相（**第 1 轮结论已被评审打回、按实测重写，不再用"判别力没有被削弱"这种一刀切的措辞**）：
  - T6-1（含 T6-1b / T6-1c）、T6-3、T6-5：从第一次做起就是干净的断言失败，红的理由与预期一致。
  - T6-2 / T6-4 / T6-6 这几组，第 1 版的"红"混进了替身崩溃的假象（`_StubConn` 只有 `close()`，闸被删之后 `main()` 走到 `rebuild_all` 才炸），并不能证明"闸真的挡住了"。补上共用替身 `_stub_rebuild_all` 后重做，这几组各自的真相并不相同：
    - **T6-4**：重做后是干净的红（`assert 0 != 0`），没有其它闸兜底。
    - **T6-2**：拆成两条子结论——`test_cli_refuses_to_overwrite_an_existing_manifest` 对这条变异**没有判别力**（`publish_manifest` 的原子发布独立兜底，这是文档已写明的设计性冗余，未改动该用例）；`test_cli_refuses_manifest_inside_the_v1_archive` 原来的写法（指向归档里**已存在**的文件）同样没有判别力，实测证实换成指向**不存在**的路径后才有干净的判别力，已按方案 (a) 改写该用例。
    - **T6-6**：已按 Ruling ⑬ 拆成两条独立测试（`test_cli_refuses_when_neither_old_value_source_is_given` / `test_cli_refuses_when_both_old_value_sources_are_given`），两个子场景表现不同——子场景 A（两者都不给）是一次真实的、但形态是裸异常的红（命中已被控制者列为不改的已知残留）；子场景 B（两者都给）是一条干净的红（`assert 0 != 0`），拆开之后**在这条测试自己的、每一次正常 pytest 运行里都直接可见**，不再需要靠独立复现脚本才能确认。
  详见 T6-2 / T6-4 / T6-6 各自小节的完整记录。

---

## 最终整支评审 · 一次性修复波（A/B/C 共 11 条）

背景：整支评审跑了 6 次实测探针后给出 3 条 Important（I1/I2-A/I2-B）+ 1 条延后项 triage（#7/#8 必须修）；控制者据此拆成 A（阻塞合并，4 条）/ B（强烈建议，3 条）/ C（清理，4 条）一次性派单。以下逐条记录改了什么、配了什么判据、变异证据。⚠️ C1/C2/C3 是纯文档 / 变量改名 / 注释扩写，不改变行为，没有可供变异的判据——落地证据用 `grep` 读回，不强行为它们造一个恒会通过的"变异"。

### A1 —— `read_legacy_rows` 漏 `UnicodeDecodeError`

**改了什么**：`except OSError as exc:` → `except (OSError, ValueError) as exc:`（`rebuild_training_sets.py:409`）。同时给 `read_legacy_rows` 那组三条既有用例加上"理由词"断言（`missing_file` 补断言含「读不出来」；`non_integer_column` 补断言含「不是整数」；`unparsable_sql` 原本就有「判不了」，未改），并新增 `test_read_legacy_rows_refuses_an_undecodable_file`（喂一份非法 UTF-8 字节的 p11 副本）。

**变异**：把 `except (OSError, ValueError) as exc:` 临时改回 `except OSError as exc:  # MUTATION-A1`。
- **落地证据**：`grep -n "MUTATION-A1" rebuild_training_sets.py` 命中改动那一行。
- **红的是哪条**：`test_read_legacy_rows_refuses_an_undecodable_file` —— 裸 `UnicodeDecodeError` 直接从 `read_legacy_rows` 逃出去，`pytest.raises(RebuildMismatch)` 接不住，测试变成一条未捕获异常的 `FAILED`。
- **复原后是否回绿**：是。`grep -n "MUTATION-A1"` 零命中，`pytest tests/test_rebuild_training_sets.py -q -rs` → `74 passed`。

### A2 —— `GenerateSkipException` 从 `rebuild_one` 漏出去

**改了什么**：`rebuild_one` 里 `load_gating_inputs(...)`（:113）与 `assemble_from_windows(...)`（:137）两处各包一层 `try/except GenerateSkipException`，转成 `RebuildMismatch`，与 `build_pinned_windows` 已有的同款转换对齐。⚠️ **`load_gating_inputs` 那一支需要额外处理**：它的"无覆盖 artifact"那条原始消息里**字面带着「跳过」**（`stock_coverage 无覆盖 artifact（B1 未写入）→ 无法门控，跳过`），若直接把 `{exc}` 原样嵌进 `RebuildMismatch` 的消息，"跳过"两个字会原样带出来，违反"消息里不含跳过"这条要求——加了一行 `reason = str(exc).replace("，跳过", "").replace("跳过", "")` 剥离这个词再嵌入。`assemble_from_windows` 那一支的原始消息本就不含"跳过"，未做同样处理（无此必要，见下方"不同意的判断"一节）。新增两条用例：`test_rebuild_one_wraps_gating_skip_into_rebuild_mismatch`（喂无 `stock_coverage` 行的替身连接）、`test_rebuild_one_wraps_assembly_skip_into_rebuild_mismatch`（monkeypatch `assemble_from_windows` 抛 `GenerateSkipException`）。

**变异（分两组，各自 deselect 邻居单独证明）**：

1. **gating 那一支**：把 `try/except` 整段去掉，退回裸 `gi = await load_gating_inputs(...)  # MUTATION-A2-gating`。
   - **落地证据**：`grep -n "MUTATION-A2-gating"` 命中。
   - **单独跑两条一起**：`test_rebuild_one_wraps_gating_skip_into_rebuild_mismatch` **红**（裸 `GenerateSkipException` 逃出去）；同跑的 `test_rebuild_one_wraps_assembly_skip_into_rebuild_mismatch` **仍然绿**——证明两条测试各自只盯自己那一支，不是互相顶替。
   - **复原后回绿**：是（`74 passed`）。
2. **assembly 那一支**：同样去掉 `try/except`，退回裸 `return assemble_from_windows(...)  # MUTATION-A2-assembly`。
   - **落地证据**：`grep -n "MUTATION-A2-assembly"` 命中。
   - **单独跑两条一起**：这次反过来——`test_rebuild_one_wraps_assembly_skip_into_rebuild_mismatch` **红**，`test_rebuild_one_wraps_gating_skip_into_rebuild_mismatch` **仍然绿**。两组变异分别只让对应的那一条测试变红，互不牵连，判别力精确对应各自的 try/except。
   - **复原后回绿**：是（`74 passed`）。

### A3 —— 写检测器白名单看不见 `SELECT … INTO` / `SELECT … FOR UPDATE`

**改了什么**：`assert_no_write_statements` 里 `top != "SelectStmt"` 判断之后，新增 `parsed[0].stmt.intoClause is not None` 与 `parsed[0].stmt.lockingClause` 两道显式排除（`rebuild_training_sets.py:213-218`）；docstring 里"合法面枚举不会漏"那句被证伪的主张已订正为准确说法（白名单钉的是顶层节点类名，不等于纯读，这两类由第一道 `connect_read_only()` 兜底）。⭐ 实测核实 pglast 7.13：`SELECT 1` 的 `intoClause`/`lockingClause` 都是 `None`/falsy，正向对照不会误报（见下方"跑了什么"一节的独立探针）。同时把 `test_write_detector_reports_nonzero_on_a_planted_write` 从 `for` 循环改成 `pytest.mark.parametrize`（关掉延后项 4），并把这两条新样本加进坏样本表。

**变异**：把两道新增判断整段删掉，换成 `# MUTATION-A3: intoClause/lockingClause 检查整段删掉`。
- **落地证据**：`grep -n "MUTATION-A3"` 命中。
- **红的是哪条**：`pytest tests/test_rebuild_training_sets.py::test_write_detector_reports_nonzero_on_a_planted_write tests/test_rebuild_training_sets.py::test_write_detector_passes_on_reads_only -v` → **精确 2 个 parametrize 用例红**：`[select_into]`、`[select_for_update]`；**其余 10 个坏样本用例与正向对照 `test_write_detector_passes_on_reads_only` 全部仍绿**。这正是 `parametrize` 相对于 `for` 循环的意义：`for` 循环下，只要第一个坏样本在列表里的位置排在 `select_into`/`select_for_update` 之前，`pytest.raises` 提前失败会让后面的样本永远跑不到，看不出"恰好是这两条不具判别力"；`parametrize` 让 12 条坏样本各自独立可见。
- **复原后是否回绿**：是（`74 passed`）。

### A4 —— `ReadOnlyConn` docstring 那句"钉住实际发出的语句集合"是假的

**改了什么**：**只改测试，不改生产代码**（两种写法任选，选了更强的一种）。`test_rebuild_one_issues_no_write_statements` 新增 `assert set(conn.statements) == {...两条真实 SQL 的文本...}`（第二条用 `g._KLINE_SELECT_COLS` 引用真实列清单常量，不手抄，避免列清单变化时判据跟着假红）。

**变异**：在 `rebuild_one` docstring 结尾插一行 `await conn.fetchval("SELECT pg_try_advisory_lock(1,2)")  # MUTATION-A4`。
- **落地证据**：`grep -n "MUTATION-A4"` 命中。
- **红的是哪条**：`test_rebuild_one_issues_no_write_statements` —— **精确复现评审实测**：`r.assert_no_write_statements(conn.statements)` 这一句**仍然通过**（`SELECT pg_try_advisory_lock(1,2)` 文本上就是一条干净的 SELECT，第二道判据看不出它在取锁）；紧接着的 `assert set(conn.statements) == {...}` 才**真的抓住**——错误信息里 `Extra items in the left set: 'SELECT pg_try_advisory_lock(1,2)'`。这就是「存在性检查表达不了穷尽性」的实物证据：旧判据（`assert_no_write_statements` 通过就算过）在这个变异下全程不报错。
- **复原后是否回绿**：是（`74 passed`）。

### B1 —— `main()` 从不对新清单跑 `assert_matches_pinned_targets`

**改了什么**：`main()` 的 `_run()` 里，`man = await rebuild_all(...)` 之后加一行 `assert_matches_pinned_targets(man["new"], where="本轮产出的新清单")`（:657）。⚠️ **连带影响**：这道新闸会在四处既有的「替身 `rebuild_all`」CLI 测试里被触发——它们原来都写 `"new": []`，加了这道闸后会被**提前**拦下，短路掉它们各自原本要覆盖的下游代码路径（比如"两轮不一致"测试会在还没跑到字节比对之前就先被这道闸拦住，测试表面仍然通过，但验的已经不是原来那件事了）。⇒ 新增共享助手 `_fake_pinned_new_rows()`（返回满足 `assert_matches_pinned_targets` 的三行），四个替身（`test_cli_pins_tempfile_to_the_validated_scratch_root`、`test_cli_always_verifies_determinism_even_without_any_flag`、`test_cli_does_not_publish_when_the_two_rounds_differ`、`test_cli_does_not_clobber_a_manifest_created_after_preflight`）全部改用它，让这道新闸对它们透明放行，各自原本要验的东西继续被验到。`_stub_rebuild_all`（5 个纯 preflight-拒绝用例共用）未改——那 5 条用例的 `rebuild_all` 从未被真正调用到（拒绝发生在 `asyncio.run(_run())` 之前），改了也是死代码。新增 `test_cli_refuses_when_new_manifest_does_not_match_pinned_targets`（替身给 0 行新清单，应有 3 行）。

**变异**：把新增那一行换成 `# MUTATION-B1: assert_matches_pinned_targets(...) 删掉`。
- **落地证据**：`grep -n "MUTATION-B1"` 命中。
- **红的是哪条**：`test_cli_refuses_when_new_manifest_does_not_match_pinned_targets` —— `assert 0 != 0` 失败，`main()` 老老实实把一份 0 行的"新清单"写进了 `m.json` 并返回 0。
- **复原后是否回绿**：是（`74 passed`）。

### B2 —— 交给片 2 的「清单 JSON 结构」既定事实过期

**改了什么**：①实测重跑一遍完整流程（详见下方"跑了什么"），核实发布出去的清单键集是 `{new, old, source_counts_before, source_counts_after, determinism_verified_against, statements_issued, scratch_root}` 共 **7** 个键（计划 `:2045` 原写 5 个），已同步订正 `docs/superpowers/plans/2026-09-28-trainingset-p4-1-rebuild-tool.md` 交接段（顺带修了 `:2043`/`:2045` 重复编号 `2.` 的问题，交接段现在是 1–6 顺编）。②在 `test_cli_always_verifies_determinism_even_without_any_flag` 里对 `json.loads(man.read_text())` 的键集合做集合等式断言。

**变异**：把 `man["scratch_root"] = str(scratch_root)` 这一行换成 `# MUTATION-B2: ... 删掉`。
- **落地证据**：`grep -n "MUTATION-B2"` 命中。
- **红的是哪条**：`test_cli_always_verifies_determinism_even_without_any_flag` —— `set(published) == {...7 键...}` 失败，`Extra items in the right set: 'scratch_root'`，精确点名少了哪个键。
- **复原后是否回绿**：是（`74 passed`）。

### B3 —— `publish_manifest` 对非 `FileExistsError` 的 `OSError` 裸崩

**改了什么**：`os.link(tmp, manifest_path)` 的 `try` 块里，`except FileExistsError:` 分支保持不变，新增 `except OSError as exc:` 分支（必须排在 `FileExistsError` 之后——后者是前者的子类，顺序反了会让 `FileExistsError` 分支变成死代码），转成 `RebuildMismatch`。新增 `test_publish_manifest_wraps_a_non_exists_oserror_from_os_link`（monkeypatch `os.link` 抛 `OSError(errno.EXDEV, ...)`）。

**变异**：把新增的 `except OSError as exc: raise RebuildMismatch(...)` 整段换成 `# MUTATION-B3: ... 整段删掉`。
- **落地证据**：`grep -n "MUTATION-B3"` 命中。
- **红的是哪条**：`test_publish_manifest_wraps_a_non_exists_oserror_from_os_link` —— 裸 `OSError: [Errno 18] Invalid cross-device link` 直接从 `publish_manifest` 逃出去，`pytest.raises(RebuildMismatch)` 接不住。
- **复原后是否回绿**：是（`74 passed`）。**并核实**：`FileExistsError` 分支本身在整个变异过程中原样未动，`test_publish_manifest_refuses_an_existing_destination`（验的是 `FileExistsError` 那一支）全程保持绿色，没有被这组变异波及——证明"拒绝覆盖"这条既有语义没有被本次改动碰坏。

### C1 —— 孤儿注释 `#` 与失落的 `repeatable_read` 理由

**改了什么**：`generate_training_sets.py:668` 那行光秃秃的 `#` 直接删掉；`load_gating_inputs` 的 docstring（`generate_training_sets.py:588` 附近）补上"两次读看到同一提交时点，不被并发写者撕成两半"这条理由（原句全仓已零命中，见下方"跑了什么"一节的核实命令）。纯文档改动，无判别力可测，落地证据用 `grep` 读回。

### C2 —— `_HOLES` 推导式变量 `r` 遮蔽模块 `import ... as r`

**改了什么**：`test_rebuild_training_sets.py` 的 `_HOLES` 字典里 7 处 `for r in rows` 全部改成 `for row in rows`（连带 `r.pop(...)`/`r.__setitem__(...)` 改成 `row.pop(...)`/`row.__setitem__(...)`）。纯改名，不改行为——已用 `pytest tests/test_rebuild_training_sets.py -q -rs` 确认改名前后测试数字与结果完全一致（`74 passed`）。⚠️ **不同意评审对这条的机制描述，见下方"不同意的判断"一节**：独立探针证实，在当前代码形状（lambda 包着列表推导式）下，Python 3 的推导式有独立作用域，`r` 并不会真的遮蔽到外层——描述的 `AttributeError` 场景没有用一个模拟当前代码结构的探针复现出来。改名本身仍然是合理的防御性清理（防将来把推导式换成 `for` 语句），按指示原样做了。

### C3 —— 验证目录路径闸在构造上恒通过

**改了什么**：`assert_write_target_is_safe(second, kind="验证目录")` 上方加一段注释，说明这道闸在构造上恒通过（`second` 是已校验过的 `scratch_root` 的子目录），是纵深防御而非活闸。纯注释，无判别力可测，落地证据用 `grep -n "C3：这道闸在"` 读回。

### C4 —— `out` 目录失败不回滚且需要重试提示 + 收尾提示验证目录残留

**改了什么**：`main()` 两处 `except RebuildMismatch` 失败出口（`_run()` 失败 / `publish_manifest` 失败）各加一句 `_out_dir_hint`（产出目录已建出、必须换新路径才能重跑）；成功收尾的 `print` 里补上第二轮验证目录路径与"带着 3 个 zip 永久留在 scratch 里"的提示。新增两条用例：`test_cli_prints_a_retry_hint_when_failing_after_out_dir_is_already_built`（capsys 抓 stderr）、`test_cli_success_message_mentions_the_leftover_verify_dir`（capsys 抓 stdout）。

**变异（两组，各自独立）**：

1. `_out_dir_hint` 的文本换成 `"MUTATION-C4-stderr"`。
   - **落地证据**：`grep -n "MUTATION-C4-stderr"` 命中。
   - **红的是哪条**：`test_cli_prints_a_retry_hint_when_failing_after_out_dir_is_already_built` —— `assert "已经建出" in err` 失败，stderr 里只有 `MUTATION-C4-stderr`。
   - **复原后回绿**：是（`74 passed`）。
2. 成功收尾 `print` 里"验证目录…zip…"那句删掉。
   - **落地证据**：`grep -n "MUTATION-C4-stdout"` 命中。
   - **红的是哪条**：`test_cli_success_message_mentions_the_leftover_verify_dir` —— `assert "验证目录" in out` 失败。
   - **复原后回绿**：是（`74 passed`）。

### 跑了什么，结果如何

```
cd backend && find . -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_rebuild_training_sets.py -q -rs
→ 74 passed
PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_insert_schema_version_guard.py -q -rs
→ 3 passed
PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/ -q -rs
→ 1695 passed（0 skipped；1677 + 本轮新增 18 条：A1(+1)/A2(+2)/A3(+11，1→12 个 parametrize 用例)/B1(+1)/B3(+1)/C4(+2)；A4/B2 只加强了既有断言，未新增测试函数）
```

pglast 7.13 正向对照独立探针（A3 落地前先核实过，非事后补测）：

```python
>>> from pglast import parse_sql
>>> parse_sql("SELECT 1")[0].stmt.intoClause
None
>>> parse_sql("SELECT 1")[0].stmt.lockingClause
None
>>> parse_sql("SELECT * INTO newtab FROM klines")[0].stmt.intoClause
<IntoClause rel=<RangeVar relname='newtab' ...> ...>
>>> parse_sql("SELECT stock_code FROM training_sets FOR UPDATE")[0].stmt.lockingClause
(<LockingClause strength=<LockClauseStrength.LCS_FORUPDATE: 4> ...>,)
```

B2 清单键集核实（真跑 `rebuild_all()` 一次，非静态猜测）：`rebuild_all()` 真实返回键集合 `['new', 'old', 'source_counts_after', 'source_counts_before']`（4 个）；`main()` 的 `_run()` 另加 `determinism_verified_against`/`statements_issued`/`scratch_root`（3 个）；合计 7 个，与计划订正后的新表述一致。

C1 核实：`grep -rn "撕成两半\|同一提交时点" --include="*.py" --include="*.md" .` 改之前全仓零命中，改之后命中新加的 docstring 那一行。

### 不同意的判断（如实列出，供裁决）

1. **A2 的措辞需要额外处理，不是原样照抄 `{exc}` 就够**：brief 给的示例代码 `f"...门控输入读不出来（{exc}）—— ..."` 若原样照抄，会把 `load_gating_inputs` 那一支"无覆盖 artifact"分支原始消息里的字面「跳过」也带出来，导致"消息里不含跳过"这条断言本身不成立（实测：第一次照抄后跑 `test_rebuild_one_wraps_gating_skip_into_rebuild_mismatch`，`assert "跳过" not in str(ei.value)` 失败）。⇒ 加了一行 `.replace()` 剥离该词。`assemble_from_windows` 那一支不需要这个处理（它的原始消息本就不含"跳过"）。这不是对 brief 判断的反对，是补一个 brief 没写但实测会撞到的细节，如实记录。
2. **C2 的机制描述与实测不完全相符**：brief 说"谁往里加一句 `r.LEGACY_SCHEMA_VERSION` 都会拿到 dict、炸一个莫名其妙的 `AttributeError`"。用一个模拟当前代码结构（lambda 包列表推导式）的独立探针实测：Python 3 的列表推导式有自己的作用域，推导式里的 `r` **不会**泄漏到外层，探针里紧跟着执行的 `r.LEGACY_SCHEMA_VERSION` 依然正常返回模块属性，没有炸出 `AttributeError`。⇒ 这条改名仍然做了（指示明确、且是无风险的防御性清理——防将来有人把推导式换成 `for` 语句那种真的会泄漏作用域的写法），但机制描述本身以实测为准，不认可"目前就会炸"这个具体说法，供裁决。

