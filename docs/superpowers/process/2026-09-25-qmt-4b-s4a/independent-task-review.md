# 独立任务评审 —— QMT 4b S4a 修复轮 8/9/10/11

开工自证（第一条命令，原样输出）：

```
$ git rev-parse --abbrev-ref HEAD && git rev-parse --short HEAD
qmt-4b-s4a
a59f94a5
```

工作目录全程 `/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a`，未 cd 主仓、未派子代理、未提交、未 push。
所有变异实验结束后已还原并逐字校验：

```
c1ac1f3161b6612179a768f4bcfe2bd34351888e1e5ab5b85d699d4fd91f1265  backend/qmt_fetch.py
cb86bf7d4a1cee7185dc2a1848905d4a8a4410a6cea63aab6ac68dec5e3742d4  backend/qmt_fsroot.py
$ git status --short        →  （空）
$ PYTHONDONTWRITEBYTECODE=1 ../.venv/bin/python -m pytest tests/ -q -rs   →  1611 passed
```

---

## 判定一 · 契约符合性：**通过**

逐条核对 D1–D8、§3b、§3c、§4、§5 之后没有发现代码与契约冲突，也没有发现被本四轮推翻却未订正的契约语句。
§5 覆盖表我按字面量重新枚举了一遍（见下），fix round 10 的五行与 fix round 11 的两行**引文与行号全部对得上**，
补集写法那三行（:676-677「其余落地点」、:1099、:1212）确实是必须点名的那一类，点名了。

剩下的是三条**登记完备性**的 Low：§5 一处枚举计数不可复现（M3）、一条会做模式匹配的上游清扫语句未被点名（M4）、
一处同族描述符泄漏未进 §3b（M6）。都不改变任何判定结果，故不阻断。

## 判定二 · 任务质量：**不通过**（唯一阻断项 M1；其余全部通过）

改动范围干净（无越界、无「同一事实改一处漏一处」的副本）、
新增测试的判别力我用 6 组定向变异逐条坐实过，六组全部按预期变红。
**阻断项只有一条**：`_settle_rollback` 里两条「不许被包装」的判据**零判别力**——
把它们各自拆掉，1611 条测试**一条都不红**，而我用真实运行证明两处的行为确实变了。
这正是 fix round 9 立项要消灭的那个形态（「决定只活在散文里」）的**第二次发生**，
原因是 round 9 按**语法**（`except Exception`）枚举，而同一判据还有 `isinstance` 表达式这第二种写法。
补两条测试即可闭合，不需要动产品代码。

---

## Findings（按严重度排序）

| # | 严重度 | 一行摘要 | 位置 | Reproduced |
|---|---|---|---|---|
| M1 | **Medium（阻断）** | `_settle_rollback` 的两条「不许包装在途异常」判据零判别力：拆掉任一条，1611 条测试全绿，而实跑行为确实变了 | `backend/qmt_fetch.py:1040` 与 `backend/qmt_fetch.py:1042` | **yes** |
| M2 | Low | `qmt_fsroot._close_all_or_note` 的捕获宽度 `except Exception` 无守卫；放宽成 `BaseException` 后 1611 全绿 | `backend/qmt_fsroot.py:257` | **yes** |
| M3 | Low | 契约 §5 自称枚举「`关掉`/`关闭`/`必须关`/`fd 归`（5 处）」，实测 7 行 | `docs/superpowers/specs/2026-09-18-qmt-4b-s4a-contract.md:452` | **yes** |
| M4 | Low | `<rel>.part.<pid>.<rand>.tmp` 也逃过大 spec :179 / :1057 那条**会做模式匹配**的引导态清扫（`任何 *.part`），§3b T1 只点了「回滚只删明写四条」，§5 未列名 | 契约 `§3b T1`（:299）／大 spec :179、:1057 | **yes**（glob 判定） |
| M5 | Low | 验收清单 C2 的预期「看到 3 个测试名后面都是 `PASSED`」跑不出来：`-q … -v` 相互抵消，实际输出是 `tests/test_qmt_fetch.py ...` + `3 passed, 89 deselected`，无测试名、无 `PASSED` 字样 | `docs/superpowers/acceptance/2026-09-20-qmt-4b-s4a-acceptance.md:32` | **yes**（原样粘命令跑过） |
| M6 | Low | `open_root` 保留的那句裸 `os.close(parent_fd)` 失败时会丢掉**即将返回的** `fd`，与 T5 末段 / T7 / T8 同族，却不在 §3b 任何一条里，也不在「S4b 若观察到 EMFILE，三条一起查」名单上 | `backend/qmt_fsroot.py:443`；契约 §3b T7/T8 | no（按源码定性，未做故障注入） |
| M7 | Info | 验收清单第五节引的那句英文「Review was static; filesystem-writing tests were not run」出自 `codex-r10.log`（HEAD=`65e2fafe`），不是 `a59f94a5` 上那次；r12 的原文是「Static review covered … tests were not executed in the read-only environment.」。实质结论（没跑测试）两次都成立 | acceptance 第五节 | **yes** |

### M1 详情（阻断项）

两处判据：

```python
1040    if isinstance(original, (RunTerminated, PathEscapeError)):
1041        return
1042    if not isinstance(original, Exception):
1043        return
```

**M1-a（:1040 的 `PathEscapeError`）**
变异：`(RunTerminated, PathEscapeError)` → `(RunTerminated,)`。
结果：`1611 passed`，零条变红。
真实行为差：staging 侧路径**分量**被换成符号链接时，`copy_one` 的在途异常是 `PathEscapeError`，
而回滚里的 `_cleanup_part` 自己也抛 `PathEscapeError` ⇒ `_rollback_all` 返回非空 `errors`。

```
原始：escaped type: PathEscapeError   is RollbackIncomplete: False   notes: ['回滚未完成：删 …失败——PathEscapeError: …']
变异：escaped type: RollbackIncomplete is PathEscapeError: False     errors: ['PathEscapeError']
```

即一次**信任边界破坏**被包装成 `RollbackIncomplete`。两者都终止运行，但契约 §4 第 12 条要求
S4b「扫 `.errors` 里出现 `PathEscapeError` 就按 `staging_path_escape` 记」——变异后这个
`PathEscapeError` 落在 `.original` 而不是 `.errors`，`stopped_reason` 会记错；
更直接地，本仓对 `PathEscapeError` 的地位写死为「不捕获、不包装、原样上抛」，这条判据就是它，而它没人守。

**M1-b（:1042 的非 `Exception` 放行）**
变异：`if not isinstance(original, Exception):` → `if False:`。
结果：`1611 passed`，零条变红。
真实行为差：用户在拷贝途中按 Ctrl-C（`os.read` 抛 `KeyboardInterrupt`）且回滚里删临时文件撞 `EIO`：

```
原始：escaped type: KeyboardInterrupt   is RollbackIncomplete: False
变异：escaped type: RollbackIncomplete  is KeyboardInterrupt: False
```

即**中断被吞掉**，正是 fix round 9 任务书写的那个后果（「400 只股跑着，用户按 Ctrl-C，中断在收尾路径上被吃掉，运行不停」）。

round 9 的三条测试只覆盖「中断发生在 `_close_or_note` / `_rollback_all` 删项 / `_rollback_all` 退账」这三处，
那三条路上 `_settle_rollback` **根本不会被调到**（`KeyboardInterrupt` 不是 `Exception`，会直接穿过 `_rollback_all` 的逐项 `try`），
所以 :1042 这一格没有任何测试到达过。

复现命令（每次前后各清 `__pycache__`，`PYTHONDONTWRITEBYTECODE=1`）：
变异脚本 + 两个复现脚本在
`/private/tmp/claude-501/-Users-maziming-Coding-Prj-Kline-trainer/977d1990-c18e-4b56-8f30-957c715d9c1c/scratchpad/review/`
（`mut.py` / `repro_settle2.py` / `repro_ki.py`）。

---

## Checked and found sound

**变异自证（我自己跑的，不是采信报告）**——六组全部按预期：

1. round 9 三条捕获宽度守卫**互相独立**：分别把 `qmt_fetch.py:381 / 1008 / 1013` 放宽成 `BaseException`，
   每次都**只有对应那一条**红（`1 failed, 2 passed` × 3）。round 9 声称的「三条不是同一条」属实。
2. `_write_inflight_marker` 的 `full_sync=True` → `False`：次序测试与参数测试**双双红**
   （外加 `test_copy_stock_keeps_everything_when_fsync_fails_after_marker_publication`），共 3 条。
3. `parent_fd_under` 的保护整个退回 `finally: for fd in opened: os.close(fd)`：
   评审点名的那条回归 + `test_parent_fd_under_keeps_path_escape_…` + `test_close_all_or_note_…` **三条红**。
4. `qmt_fsroot._close_or_note` 的 `if pending is None:` → `if True:`（模拟 12 个站点全退回裸关闭）：
   **13 条红**，正好是 12 条站点测试 + 那条跨模块回归 —— 12 个「要修」站点**逐个**有测试钉着，不是「其余同理」。
5. `qmt_fetch._close_or_note` 同样变异：**5 条红**（`MaxBytesExhausted` ×2、`PathEscapeError` ×2、`untracked_target_file` ×1）；
   另两条（退账 / 清已发布 `.part`）走的是「没有异常在途」那一支，由 M-c / M-d 两个变异分别打红。
6. `_CloseFd.__exit__` 传 `None` 而不是 `exc` → 4 条红；`copy_one` 的 `parts` 不纳入 `<rel>.part` → 2 条红。

**契约 §5 的字面量枚举，我重新做了一遍**（用 `/usr/bin/grep`，不走遵守 `.gitignore` 的包装）：

- `fsync|F_FULLFSYNC` 命中 **53 行** —— 与契约自称的「53 处」相符；
- `finally` **2 处**（:609 / :641）、`os.close` **3 处**（:98 / :103 / :642）、`描述符` **1 处**（:1325）—— 全部相符；
- 逐行核对被点名的七句原文与行号：`:468` / `:694` / `:676-677` / `:1099` / `:1212` / `:609` / `:641-642`
  **引文逐字对得上**，且 `:676` 与 `:1099` 确实是用「其余落地点」这个**补集**指代在途标记、整句不含 `inflight` 字样
  —— 按概念搜词确实搜不到，契约那段自省成立；
- `:98 / :103`（`os.close(fd); fd = nxt`）判「逐字继续有效」属实：实现 `qmt_fsroot.py:382-383` 就是这一句，本轮没动；
- 我另外找了**可能被漏掉**的：`:1097`（「manifest 提交与 O2-F1 顺序屏障**两处**……断言是 `F_FULLFSYNC`」）
  是存在性断言、不是穷尽性断言，不因新增第三处而失效 ⇒ 不列名是对的；
  `:62` / `:463`（`.part` → `fsync` → `os.replace`）说的是 `.part` 那一侧，本片没碰；
  `:623`（staging 内一切动作经 `open_under`/`parent_fd_under`）仍成立（`atomic_write_json` 内部就是这么走的）。

**代价表 §3b 的每一条我都回代码核过，描述与行为一致**：

- T4「**从准备发布那一刻起**把 `<rel>.part` 列进回滚名单」＝ `qmt_fetch.py:726` `parts = (tmp, rel + PART)` 排在 `_publish_part` 之前；
  「非普通对象照旧原样留着」＝ `_cleanup_part` 开头的 `_part_is_non_regular` 早返回（:972）；
  「`copy_stock` 主回滚在同一条失败路径上本来就会删这个名字」＝ `:1308-1309` 无条件对两个 rel 都删，属实。
- T5 末段「`_open_source_leaf` 与 `classify_target` 成功路径上父目录关闭失败会吃掉叶子 fd」
  ＝ 两处的 `return` / `fd` 赋值都在 `with _CloseFd(pfd)` **之内**（:434-440、:830-838），属实。
- T6「12 个落在异常展开路径上的关闭点」＝ BASE `3b6e2dfb` 上 `qmt_fsroot.py` 恰 **14 个** `os.close`，
  现存裸 `os.close` 恰 **2 个**（:382 / :443）＋ 判据自身那句（:232），12+2 对得上。
- T7「本轮改善了邻居：此前第一个关闭失败让其余一个都关不上」＝ `_close_all_or_note` 逐项独立 + 只上抛第一个（:253-263），属实，并有测试。
- T8「裸 `os.close(fd)` 抛出 ⇒ `fd = nxt` 不执行 ⇒ `nxt` 漏；外层对同一 `fd` 再关一次」＝ `:379-383` + `:407-409`，属实。
- D6 的代价数字「`full_fsync` 调用数 2 次 → 4 次」：我打桩实测一只股的完整序列，
  `Counter({('fsync','dir'):5, ('fsync','file'):2, ('full_fsync','file'):2, ('full_fsync','dir'):2})`，
  **4 次属实**；且次序是「标记内容屏障 → 标记目录项屏障 → 两次 final 替换的普通 `fsync(子目录)` → commit_stock 两道屏障 → 删标记的普通 `fsync`」
  —— 「其余落地点一个都不动」属实，D6 验收第 1 条钉的相对次序属实。
- D7 累计语义：同一次实测 `committed_bytes` = 26(export_log) + 35 + 50 = **111**，与「旧值 + 本次真正写盘」一致。

**§3c「破例动 `qmt_fsroot`」的范围声明我逐条核过**：

- `__all__` 与所有 `^def` / `^class` 的公开名单 **与 BASE 逐字相同**，只多了 4 个私有物（`_close_or_note` / `_close_all_or_note` / `_CloseFd` / `_CloseFds`）；
- 验收 D2/D3/D4/D5 我原样跑了一遍，**四条全部复现**：D2 无输出；D3 = `1 file changed, 174 insertions(+), 59 deletions(-)`；
  D5 = 删掉 33 行、其中带业务调用 0 行；且我按「报 0 必须先证明能报非 0」的规矩，
  往被删行清单里塞一行 `os.replace(...)` 后它**确实打印 1** ⇒ 那个 0 是真结论；
  被删的 33 行我逐行看过，全是 `try:` / `finally:` / `except BaseException:` / `os.close(...)` 与一行 docstring，**没有一行业务调用**。

**改动范围**：round 8 / 10 只碰 `qmt_fetch.py` + 测试 + 契约；round 9 只加测试；round 11 碰 `qmt_fsroot.py`（user 已拍板）＋测试＋契约＋验收清单。
`qmt_manifest` / `qmt_pool` / `qmt_ingest` / `qmt_normalize` 相对 `main` **零改动**（实跑 D2 为空）。
大 spec 在本区间**一字未改**。`docs/acceptance/2026-09-07-…` 那 49 行来自 merge 进来的 #193，不是本分支的手笔。

**治理**：`codex-r12.log` 显示 HEAD=`a59f94a5`、base=`daa3b446`（merge 之后的正确基准）、`verdict=approve`、ledger 已写。
验收清单第五节的「它没跑测试」「它只逐字比对了两个程序文件」与日志里的实际命令一致，披露是诚实的。

**其他探到并确认无误的**：
异常三族互不相交且 `RollbackIncomplete` 只在「原异常不是终止信号」时才铸（:1036-1045）；
`copy_stock` 的 `written` 只收成功项 ⇒ 不会双退账；
标记写失败时 `_inflight_marker_on_disk` 保守答 `True`（`follow_symlinks=False`）⇒ 不会误删授权凭据；
两次 `_replace_part_to_final` 之后的 `fsync(子目录)` 仍是普通 `fsync`（未被 round 10 波及）；
`grep -c argparse qmt_fetch.py` = 0；全套 `1611 passed / 0 skipped`，与验收 B2 写的数字一致。

---

## Not covered

- **断电耐久本身没验**。D6 的结论是耐久性推理，本仓（和我）都做不了断电实测；我只验了**次序**与**传下去的参数**这两半，
  以及「`full_sync=True` 在 `qmt_fsroot` 里确实下两道屏障」这条实现事实。
- **只在 macOS 上跑过**。CI 是 Linux，两条平台相关处我只做了静态判断：
  ①`full_fsync` 在无 `F_FULLFSYNC` 的平台退回 `os.fsync`，而测试判据放在 `qmt_fsroot.full_fsync` 这一层，Linux 上仍有判别力；
  ②round 11 那条回归断言 `errno in (ELOOP, ENOTDIR)`，我本机实测走的是 `ENOTDIR` 那一支，**`ELOOP` 那一支没跑到**。
- **`qmt_fetch` 的 12 个关闭点我没逐点做故障注入**，只做了两组「全站点」变异（`_close_or_note` 两个分支各一次）
  加四组定点变异。round 8 报告里判「两者都不会」的 6 处（`_part_is_non_regular` / `_probe_part` / `rfd` / `classify_target` 目标 fd /
  `_cleanup_part` / `_replace_part_to_final`）我是**读代码核的定性**，没有各自造一次失败去证伪。
- **`qmt_manifest.commit_stock` 内部我没审**（禁改模块，且已登记的阻断级残留 R1 就在那里）。
  D7 的累计语义我只验了 `copy_stock` 这一侧写进去的值，没验转移守卫在多轮崩溃重拉下的累积行为（E11/E12 我没复跑）。
- **契约 §1 的 13 条实测事实（E1–E13）我没有复跑**，探针脚本在 `docs/superpowers/evidence/2026-09-18-qmt-4b-s4a/`。
  它们支撑 D2/D6/D7 的取舍理由；我核的是「契约写的行为 = 代码的行为」，不是「探针当初测出来的是不是这个数」。
- **评审账本本身没读**（`.claude/state/` 读取被权限拒绝）。治理结论我是从 scratchpad 里的 `codex-r*.log` 复核的，
  那不是权威账本；`codex-r1..r3` 的日志也不在那里，所以验收清单里「5 次真判决 / 4 次撞额度 / 1 次作废」的完整计数我核不全
  （r4–r12 这 9 次我核过：3 次 needs-attention、3 次撞额度、3 次 approve，其中 `r8` 的 HEAD 早于 merge —— 与「作废那次基准不对」的说法吻合）。
- **`docs/acceptance/2026-09-07-backend-tests-required-check.md` 我没审**（来自 merge 的 #193，不属本四轮）。

---

## 我最没把握的一条

**M4**。我判「`<rel>.part.<pid>.<rand>.tmp` 逃过大 spec :179 / :1057 的引导态清扫枚举，应当进 §5 或 §3b T1」——
但反向自问之后，这个状态在契约里**可能其实是合法的**：T1 已经把「这个临时文件不会被回收」整条登记为**已接受**的代价，
并明写「启动清理若要回收它，需要一条**新的**清扫规则」；若把 T1 读成「对**一切**回收路径都成立」，那 :179 / :1057 就只是
「已登记代价的又一个落点」，不是一句**被推翻**的语句，按「不列名即不覆盖」的纪律本来就不该进 §5。
我倾向于仍然报它，理由是 T1 的正文只点了「S4b 的回滚只删标记里明写的四条、**不做模式匹配式清扫**」这一条路径，
而 :179 / :1057 恰恰**是**一条做模式匹配的路径 —— 读 T1 的人会以为「做模式匹配的那条路径能兜住」。
但这条更像措辞完备性，而不是一条真缺口；如果控制者判它不该进表，我不会坚持。
