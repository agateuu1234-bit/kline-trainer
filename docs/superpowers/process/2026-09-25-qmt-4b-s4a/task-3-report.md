# Task 3 报告：在途标记 + 单股事务编排

## 位置确认

```
$ cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a" && git rev-parse --abbrev-ref HEAD && git rev-parse --short HEAD
qmt-4b-s4a
f8af7adf
```

开工前 base 是 `f8af7adf`（Task 2 fix round 1 的提交），与任务书给定的 base 一致。

完工后提交（commit SHA 见下方“提交”一节；本报告文件本身不进 git —— `.superpowers/`
在 `.gitignore:63` 里，与 Task 1/2 报告同规格）。

## 交付的文件（修改，非新建）

- `backend/qmt_fetch.py`：+约 210 行。新增 `SourceChangedMidRun` 异常类
  （`RunTerminated` 第二个成员）、`INFLIGHT` 常量、`build_inflight_marker`、
  五个私有编排辅助（`_validate_stock_paths` / `_cleanup_part` /
  `_replace_part_to_final` / `_write_inflight_marker` / `_remove_inflight_marker` /
  `_apply_stock_records`）、以及顶层入口 `copy_stock`。Task 1/2 的既有符号
  一个字节未改（只在 import 段新增了 `atomic_write_json` / `fsync_dir` /
  `split_relative_components`（qmt_fsroot）、`commit_stock` / `RunLedger`
  （qmt_manifest）、`QmtSchemaError` / `parse_qmt_filename`（qmt_normalize）、
  `Slot`（qmt_pool）四个模块的 import）。
- `backend/tests/test_qmt_fetch.py`：+15 个测试（未改动 Task 1/2 已有的 30 个），
  外加两个通用测试起点辅助函数 `_seed_manifest` / `_begin_session`。

## 公开符号与签名（S4b 要接的接口）

⚠️ **本节维护到 fix round 2 为止的最新状态**（下方带 fix round 编号处标注
了哪次修复改的）——这是 N3 订正的教训：这份原本写在首次交付时的参考块，
在 fix round 1 改了标记形状与异常分类之后没有跟着改，S4b 若照抄这里会拿
到已经被订正掉的旧接口。**下方是唯一权威版本，不要再参考本节以外任何
更早的草稿。**

```python
INFLIGHT = ".inflight.json"

def build_inflight_marker(slot: Slot, rel_1m: str, rel_daily: str) -> dict:
    """返回 {"code": str, "universe_idx": int, "targets": [str, str],
    "parts": [str, str], "started_at": str}（fix round 1 · C1：大 spec
    §4.5:468 钉死的五字段形状，不含 market）。"""

class SourceChangedMidRun(RunTerminated):
    """终止条件族第二个成员（D5）。构造：SourceChangedMidRun(detail: str)。"""

def copy_stock(
    src_fd: int, stg_fd: int, slot: Slot, rel_1m: str, rel_daily: str,
    manifest: dict, *, ledger: RunLedger, budget: ByteBudget,
) -> tuple[str, dict]:
    """返回 ("skipped", manifest) 或 ("committed", 提交后的 manifest)。

    可能逃出的异常（fix round 2 · N1/N2 之后的最终分类）：
    · `qmt_normalize.QmtSchemaError` / `qmt_fsroot.PathDisciplineError`——
      两条路径次序互换、或文件名解析出的代码/周期与 slot/次序不符。
      **不属于任何一族**，是调用方违反了本函数的前置契约，不许记成
      failures 的 reason（该全集闭合）。
    · 裸 `TypeError`——`slot` 不是 `qmt_pool.Slot`。同样不属于任何一族。
    · `StockCopyFailed`（候选失败，reason 三选一：`fetch_missing_file` /
      `fetch_copy_hash_mismatch` / `untracked_target_file`——最后一个现在
      也覆盖“账本记录挂着与本次调用不同的 relative_path”，fix round 2 ·
      N1：账本对某个周期已有记录、但 relative_path 与本次调用不一致时，
      在四象限之前就拒绝，不等四象限/落地前比对把它放过去）。
    · `RunTerminated` 子类（`MaxBytesExhausted` / `SourceChangedMidRun`，
      终止条件）。
    · `qmt_fsroot.PathEscapeError`（路径逃逸，原样上抛）。
    · **标记写下之后**，`commit_stock` 可能抛出的任何异常（含
      `qmt_manifest.ManifestInvalidError`）都必须按“整次运行终止”处理，
      判据是位置（标记已写下）不是类型。
    """
```

`.inflight.json` 的**在盘形状**就是 `build_inflight_marker` 的返回值，逐字
`{"code": <str>, "universe_idx": <int>, "targets": [<str>, <str>],
"parts": [<str>, <str>], "started_at": <str>}`——**不含 `market`**
（fix round 1 · C1 订正：大 spec §4.5:468 没有把它列进这份形状；S4b 需要
时可从 `code` 的后缀派生）。

## 每一条决策（brief 没答、由我做的判断）

1. ~~在途标记只含三个字段（`code`/`market`/`universe_idx`），不含两条相对
   路径。~~ **⚠️ 已被 fix round 1 · C1 订正**：大 spec §4.5:468 钉死的形状
   是五字段（`code`/`universe_idx`/`targets`/`parts`/`started_at`），本决策
   最初漏了 `targets`/`parts`/`started_at` 三个、多写了一个 spec 未提及的
   `market`。现状见上方“公开符号与签名”一节与本文件 fix round 1 小节。
   以下是**原始决策记录**（历史存档，不代表当前实现）：
   理由：契约 D1 交接单第 1 条把「由 `Slot` 解析出两条相对路径」明确划给
   S4b；S4b 在崩溃恢复时会用**同一套**解析逻辑重新推导出这两条路径（它本来
   就要为“重试这个槽位”调一次），没有必要在标记里再存一份可能与解析方式
   漂移的副本。三字段恰好覆盖 `qmt_manifest.RecoveryScope` 的三个构造参数。
   ⚠️ **命名不对齐**：标记字段用 `code`（契约原文“要写 code 与
   universe_idx”），而 `RecoveryScope` 的对应参数名是 `stock_code`——S4b 用
   标记构造 `RecoveryScope` 时要做一次改名（`RecoveryScope(stock_code=
   marker["code"], market=marker["market"], universe_idx=marker["universe_idx"])`），
   不是逐字段同名传参。**这是我做的选择，不是契约写死的**，请复核是否要改成
   `stock_code` 以消除这次改名。
2. **不导出 `_write_inflight_marker` / `_remove_inflight_marker`**（下划线
   前缀，仅 `copy_stock` 内部用）。brief 原文「`.inflight.json` 的形状定义
   （模块级常量 + 构造函数，S4b 将导入它）、写与删」，我把它读成一句话两个
   分句：分句一（常量+构造函数，S4b 导入）已实现为公开的 `INFLIGHT` +
   `build_inflight_marker`；分句二（写与删）读成「Task 3 自己实现标记的写
   与删」（即 `copy_stock` 内部完成，不是另外导出两个函数给 S4b 调）。S4b
   若需要在崩溃恢复流程里删除一份**孤儿**标记，可以直接 `os.unlink` +
   `fsync_dir`（两个原语都已从 `qmt_fsroot` 公开），未必需要复用我这两个
   私有函数。**这里存在另一种合理读法**（导出写/删两个函数），如果 S4b
   需要请告诉我，我可以把它们去掉下划线前缀直接导出（改动极小）。
3. **`copy_stock` 不接受/不使用 `qmt_manifest.RecoveryScope`**。契约 D6 交接
   单第 2 条明写“`copy_stock` 抛出的任何异常，只要发生在标记写下之后，一律
   终止本次运行……S4a 只负责抛，S4b 负责收”，崩溃恢复（含调用
   `commit_stock(..., recovery=...)` 去清空某只股的记录）整个不在本函数职责
   内。我写了一条独立测试（`test_recovery_removing_a_stock_leaves_
   committed_bytes_unchanged_and_is_accepted`）直接驱动已合并的
   `qmt_manifest.commit_stock` + `RecoveryScope`，只是为了证明 D7 选的“累计
   写入量”语义（`copy_stock` 从不主动回退 `committed_bytes`）与
   `qmt_manifest` 的转移守卫兼容（E10/E11 的“原值不动可接受”），不代表
   `copy_stock` 自己实现了任何恢复逻辑。
4. **`copy_stock` 不检查/不依赖 `.staging.lock`**。读了 `qmt_manifest.py`
   全文，`begin_run`/`commit_stock`/`commit_final` 都不引用锁状态——取锁纪律
   完全是 CLI/S4b 层的事。测试里 `_begin_session` 因此也没有取锁，直接
   `atomic_write_json` 写 manifest 后调 `begin_run`。
5. **`.inflight.json` 的写/删只用普通 `fsync_dir`，不用 `F_FULLFSYNC`。**
   大 spec §4.4 的“耐久提交协议闭合清单”（契约在 S4a 范围内继续生效、未被
   任何 D 条款覆盖）逐条列名到“`.inflight.json` 的创建与删除→各自之后
   `fsync(staging)`”，用词是 `fsync`，不是 `F_FULLFSYNC`；清单里明确说
   `F_FULLFSYNC` 只用在 “manifest 提交” 与 “O2-F1 那道顺序屏障”（崩溃回滚
   删两条 final 之后、删标记之前的那道屏障，属于 S4b 的崩溃恢复范围，不在
   本函数里）。两次 `.part→final` 的 `os.replace` 之后同理只用 `fsync_dir`
   （清单原文就是 `fsync`）。
6. **失败路径清理 `.part` 时不追加 `fsync`。** 大 spec 同一份闭合清单把
   “失败路径上 `.part` 的删除”列为**显式豁免**（`.part` 不匹配导入侧 glob，
   残留只会在重试时被覆盖或再删一次），我照此实现（`_cleanup_part` 只
   `unlink`，不 `fsync`）。
7. **D5 的比较对象是“任何有记录的格”，用 `rec is not None` 统一判断**，不是
   只在 `verdict == TARGET_RECOPY` 时才比较——这直接落实契约 D4 第 2 条
   （“有记录 × 目标不存在”那一格也要比对），用同一段代码同时覆盖“重拷”与
   “有记录但目标缺失后正常拷贝”两种情形，避免两处分叉实现后走漂。
8. **`committed_bytes` 直接取 `budget.used`**，不是独立地用
   `旧值 + sum(本次写盘字节)` 重新计算一遍。两者数学上等价（`ByteBudget` 本
   来就是“调用方在运行开始时把 `.used` 初始化成 manifest 的
   `committed_bytes`，随后逐块累加”），但直接复用 `budget.used` 保证
   `copy_stock` 输出的 `committed_bytes` 与预算对象自身的记账**不可能漂移**
   （不存在“两处各自算一遍、算法悄悄不同步”的窗口）。
9. **`copy_stock` 的“失败/终止路径清理”对候选失败（`StockCopyFailed` 等）
   与终止条件（`SourceChangedMidRun`/`MaxBytesExhausted`）用同一段
   `except BaseException` 处理**（都做“删两个 `.part` + 退还预算 + 原样上
   抛”），因为 brief 原文把两者的清理动作写在同一句里（“失败/终止路径：
   删该股两个 `.part`、退还预算、原样上抛”），且两者发生的时机都严格早于
   在途标记，清理逻辑没有分叉的必要。`PathEscapeError`（第三族）若在这段
   期间被抛出，同样会经过这段 `except BaseException` 做“清理+`raise`”，但
   `raise`（裸重抛）不改变异常类型/内容，不构成契约里“不捕获、不包装”禁止
   的“捕获并转换”——这与 Task 1 `copy_one` 自己的 `except BaseException:
   ...; raise` 是同一惯例（那里面同样可能经过会抛 `PathEscapeError` 的
   `open_under`/`parent_fd_under`）。
10. **`copy_stock` 对 `manifest` 的内部结构（`files`/`pool_order`/`cursor`
    是否存在、类型对不对）不做防御性校验**，直接索引访问（`manifest["files"]`
    等）。这与 Task 1/2 对“外部不可信输入”（`record` 字段、源/目标文件类型）
    的防御姿态不同——`manifest` 由调用方（S4b）负责维护，其最终形状会在
    `commit_stock` 内部的 `validate_manifest` 处被闭合校验，`copy_stock` 自
    己再加一层形状校验是重复且超出本片范围的（CLAUDE.md「no error handling
    for impossible scenarios」）。`slot` 例外——契约明写“`Slot` 不能省”，
    我加了 `isinstance` 检查（`TypeError`）。

## 必需证据（8 项，逐项列出测试名 + 结果）

以下命令均在
`cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend"`
下用 `../.venv/bin/python -m pytest` 执行；套件命令前已清 `__pycache__`。

1. **端到端正路**：`test_copy_stock_happy_path_end_to_end_commits_both_files`
   （+ `test_copy_stock_skips_when_both_files_already_match` 覆盖 D8 全 skip
   分支）——断言两 final 落地、无 `.part`/标记残留、`files` 恰 2 条、
   `pool_order[SH]` 一条锚点、`cursor[SH]` 从 0 推进到 1、`committed_bytes`
   含 export_log 基线、且落盘那份与返回值逐字相等。
2. **D1 验收 + 变异**：`test_copy_stock_rejects_swapped_period_order_before_
   marker_written`、`test_copy_stock_rejects_path_whose_filename_code_does_
   not_match_slot`——均断言拒绝早于标记（标记不存在、两个 final 都不存在）。
   变异见下方“变异证据”第 1 组。
3. **R37-F1 回归钉**：`test_copy_stock_daily_missing_leaves_no_orphan_1m_final`
   ——daily 源整段目录缺失，断言 1m 的 final 不残留、`.part` 不残留、预算
   原样退还。
4. **D5 验收**：`test_copy_stock_terminates_before_marker_when_local_corrupt_
   and_source_swapped`——本地目标同尺寸内容损坏（触发 RECOPY 判据）+ 源同尺寸
   换代，断言标记未写、两个 `.part` 均无残留、`cursor` 未动、manifest 落盘
   字节逐字未变（提交前后原样比对整份文件字节）。
5. **D4 第 2 条**：`test_copy_stock_terminates_when_recorded_absent_target_and_
   source_changed`——先用 `classify_target` 断言这一格确实落在
   `TARGET_COPY`（不是 `TARGET_RECOPY`），再驱动 `copy_stock` 断言同样终止、
   目标未被造出来。
6. **D6 验收 + 变异**：`test_copy_stock_marker_present_on_disk_during_each_
   final_replace`——monkeypatch `os.replace`，对两条目标 basename 的每一次
   调用都在**调用前**记录标记是否在盘上，断言 `[True, True]`。变异见下方
   第 2 组。
7. **耐久验收 + 变异**：`test_copy_stock_fsyncs_directory_after_each_final_
   replace`——同时 monkeypatch `os.replace` 与 `qmt_fetch.fsync_dir`，记录
   事件序列，断言每一次目标 `replace` 事件的**下一个**事件必须是 `fsync`
   （不是简单计数，避免被 `_remove_inflight_marker` 自己那次 `fsync_dir`
   混进总数里）。变异见下方第 3 组。
8. **D7 验收**：`test_copy_stock_committed_bytes_is_old_value_plus_actual_
   bytes_written`（seed 一个与任何 `files` 记录都不对应的“旧值”，断言
   `committed_bytes == 旧值 + 本次两文件字节数`，且与 `budget.used` 一致）+
   `test_recovery_removing_a_stock_leaves_committed_bytes_unchanged_and_is_
   accepted`（直接驱动 `qmt_manifest.commit_stock` + `RecoveryScope`，证明
   “删记录、`committed_bytes` 原值不动”被接受——D7 崩溃恢复第③档一半）。

补充（非 brief 明确列出，属“自己审计发现的形状”）：
`test_source_changed_mid_run_is_a_run_terminated_family_member`（异常家族
互不相交，`SourceChangedMidRun` 加入 `RunTerminated`）、
`test_build_inflight_marker_shape` / `_rejects_non_slot`、
`test_copy_stock_does_not_leak_fds_across_repeated_calls_for_distinct_stocks`
（5 只股连续 `copy_stock`，`/dev/fd` 计数前后差 ≤2——对照 Task 1/2 报告里
“fd 泄漏是常见漏判别力点”的教训）。

## 变异证据（3 组，pytest 原始输出，已清 `__pycache__`、neighbours deselected）

### 第 1 组：D1 前置校验被删

```
$ sed -i '' 's/_validate_stock_paths(slot, rel_1m, rel_daily)/# _MUTATION: _validate_stock_paths(slot, rel_1m, rel_daily)/' qmt_fetch.py
$ find . -name "__pycache__" -exec rm -rf {} +
$ ../.venv/bin/python -m pytest tests/test_qmt_fetch.py -q -rs \
    -k "test_copy_stock_rejects_swapped_period_order_before_marker_written or test_copy_stock_rejects_path_whose_filename_code_does_not_match_slot"
```
输出（节选，两条都变红）：
```
FF                                                                       [100%]
=================================== FAILURES ===================================
______ test_copy_stock_rejects_swapped_period_order_before_marker_written ______
...
qmt_fetch.py:580: in copy_stock
    committed = commit_stock(stg_fd, new_manifest, ledger=ledger)
...
qmt_manifest.py:416: in _validate_files
    _require(f_period == rec["period"], ...)
E   qmt_manifest.ManifestInvalidError: files[0] 自称周期是 '1m'，而文件名解析出的是 'daily'——
    把 1m 的哈希绑到 daily 上，校验的字节与导入器消费的字节就不是同一批了
_____ test_copy_stock_rejects_path_whose_filename_code_does_not_match_slot _____
...
E   qmt_fetch.StockCopyFailed: fetch_missing_file: 1m/600001.SH_other_1分钟K线_前复权.csv: ...
2 failed, 43 deselected in 0.27s
```
**红的原因与契约 D1 自己的警告逐字对应**：没有前置校验的实现确实“一路跑到
`commit_stock` 才被 `_validate_files` 拒掉”——而我的测试断言的是
`pytest.raises(QmtSchemaError)`（早期、字符串级拒绝），不是任意异常，所以
`commit_stock` 深处抛出的 `ManifestInvalidError` 被判定为“错误的失败原因”，
测试正确变红（若只断言“抛了某个异常”就会是假绿，命中契约自己点名的陷阱）。
已还原（`git diff` 确认逐字复原）。

### 第 2 组：D6 标记写下时机挪到两次 replace 之后

```
$ 把 `_write_inflight_marker(stg_fd, slot)` 从「两次 replace 之前」挪到「两次 replace 之后」
$ find . -name "__pycache__" -exec rm -rf {} +
$ ../.venv/bin/python -m pytest tests/test_qmt_fetch.py -q -rs \
    -k "test_copy_stock_marker_present_on_disk_during_each_final_replace"
```
输出：
```
1 failed, 44 deselected in 0.25s
E   AssertionError: 两次 .part→final 的 os.replace 发生时，在途标记都必须已经在盘上
E   assert [False, False] == [True, True]
```
`status` 仍是 `"committed"`（happy path 本身不报错，正是 brief 强调的“正路上
看不出问题”那种）。已还原。

### 第 3 组：`os.replace` 之后的目录 `fsync` 被删

```
$ 在 _replace_part_to_final 里注释掉 fsync_dir(pfd)
$ find . -name "__pycache__" -exec rm -rf {} +
$ ../.venv/bin/python -m pytest tests/test_qmt_fetch.py -q -rs \
    -k "test_copy_stock_fsyncs_directory_after_each_final_replace"
```
输出：
```
1 failed, 44 deselected in 0.24s
E   AssertionError: os.replace 之后紧跟的必须是 fsync_dir，实测事件序列
    [('replace', '600000.SH_x_1分钟K线_前复权.csv'), ('replace', '600000.SH_x_日K线_前复权.csv'), ('fsync', 12)]
```
同一变异下把整份 `test_qmt_fetch.py`（不 `-k`）跑一遍，确认**只有这一条**
变红、其余 44 条仍绿（`1 failed, 44 passed`）——满足“红的是这一条”。已还原。

变异全部还原后，`grep -n "_MUTATION" backend/qmt_fetch.py backend/tests/
test_qmt_fetch.py` 无命中；`git diff --stat` 只剩 `qmt_fetch.py` +
`tests/test_qmt_fetch.py` 两个文件的合法改动。

## 套件结果

```
$ cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend"
$ find . -name "__pycache__" -exec rm -rf {} +
$ ../.venv/bin/python -m pytest tests/ -q -rs
1550 passed in 34.36s
```
任务书给定的开工前基线是 **1535 passed**；本片新增 15 条测试，**1550 passed，
skipped = 0**。

## 未覆盖 / 交给 S4b 的部分（如实登记，不是我漏做）

- 两条相对路径怎么从 `Slot` 解析出来——契约 D1 明写不选路线、交 S4b，本片
  只做“收到路径之后的前置校验”。
- 崩溃恢复（读 `.inflight.json`、构造 `RecoveryScope`、清理孤儿 final、删
  孤儿标记）——契约 D6 交接单明写“S4a 只负责抛，S4b 负责收”。O2-F1 那道
  “先 `fsync` 各自 final 目录、才允许删 `.inflight.json`”的顺序屏障属于这条
  恢复路径，不在 `copy_stock` 里（`copy_stock` 自己成功路径上的标记删除，
  前面已经有 `commit_stock` 的 `F_FULLFSYNC` 兜底，不涉及“删 final”）。
- 续跑循环、`begin_run` 调用时机、锁纪律——均是 S4b 范围。
- D2 “有记录那半边”的残留（一只股同时出现在 `pool_order`+`files` 与
  `failures` 里）——契约原文写明“本片不解决……交接 S4b”，`copy_stock` 遇到
  `TARGET_UNTRACKED` 只单纯 `raise StockCopyFailed`，不touch manifest。

---

## Fix round 1（评审：spec ❌ / quality changes-requested，2 Critical + 4 Important）

评审逐条见协调者转发原文，此处只记我做了什么、怎么验证的。**过程中被
HTTP 429 打断过一次；协调者把已完成的 C1/C2 提交为 checkpoint
`4b97a055` 并核实过（套件 1551 passed），本轮从那里继续，未重做。**

提交序列（均在 `qmt-4b-s4a` 分支，未 push）：

```
615e50f 任务三修复第 1 轮 · I4：钉住异常分类不是靠文档自称
e45e830 任务三修复第 1 轮 · I3：成功重拷提交路径新增覆盖 + 订正 max() 的文档误判
0ceaaa9 任务三修复第 1 轮 · I2：新增测试守住标记删除之后的 fsync
6b2f1bf 任务三修复第 1 轮 · I1：durability 测试改核对 fsync 的确切目录 fd
4b97a055 WIP 任务三修复第 1 轮：C1 标记形状补齐 + C2 比对查找键改按周期（协调者 checkpoint）
6c1b9e24 QMT 4b S4a Task 3：在途标记 + 单股事务编排（fix round 1 之前的原始交付）
```

### C1（Critical）· 标记形状补齐，删掉 spec 未提及的字段

`build_inflight_marker` 从 `{code, market, universe_idx}` 改成大 spec
§4.5:468 钉死的 `{code, universe_idx, targets: [两条 staging 内相对路径],
parts: [两条 .part 路径], started_at}`。**不含 `market`**——评审明确裁定
「除非能指出钉住它的原文，否则去掉；`RecoveryScope` 可以从 `code` 后缀
派生」，我核对过大 spec:468 的原文确实只有五个字段、没有 `market`，照此
执行。`targets`/`parts` 就是 `copy_stock` 这次事务实际会去 `os.replace`/
`unlink` 的那两条路径本身（`rel_1m`/`rel_daily` 与它们各自 `+ PART`），
不是让 S4b 事后重新解析。`started_at` 用
`datetime.now(timezone.utc).isoformat()`（spec 未定格式，只要求存在；
纯诊断字段，无消费者对格式有要求）。

签名从 `build_inflight_marker(slot)` 变为
`build_inflight_marker(slot, rel_1m, rel_daily)`；`_write_inflight_marker`
同步加两个参数。**这是签名破坏性变更**——由 checkpoint 完成，本轮只是
确认（`test_build_inflight_marker_shape` 已改成断言新五字段形状 + `"market"
not in marker`）。

### C2（Critical）· 比对查找键改按 `(stock_code, period)`

`copy_stock` 原来用 `by_key = {(stock_code, relative_path): record}` 去查
一只股某个周期有没有账本记录；改成 `by_period`，只按 `(在这只股名下,
period)` 查，不看 `relative_path`。理由与验证同评审原文：账本记录若挂在
与本次调用不同的 `relative_path` 下（`{name}` 段的解析方式在契约 D1 里
明写尚未选定），按路径查会查不到、把「有记录」误判成「无记录」，
D4 第 2 条的比对被静默跳过，两个 final 落地、标记写下，直到
`commit_stock` 才因 `_validate_files` 拒绝——那时标记与 final 都已经在
盘上。由 checkpoint 完成；本轮新增回归测试
`test_copy_stock_detects_mismatch_when_existing_record_has_a_different_
relative_path`（账本记录挂旧路径、本次调用给新路径、源内容已变），确认：

```
$ find . -name "__pycache__" -exec rm -rf {} +
$ ../.venv/bin/python -m pytest tests/test_qmt_fetch.py -q -rs \
    -k test_copy_stock_detects_mismatch_when_existing_record_has_a_different_relative_path
1 passed, 45 deselected in 0.21s
```

**变异**：把查找键退回 `by_key`（按 `relative_path`），单独跑该测试：

```
E   qmt_manifest.ManifestInvalidError: per-stock 提交 会把已提交的 files 记录
    ('600000.SH', '1m', '1m/600000.SH_旧名字_1分钟K线_前复权.csv') **回滚**掉——
    调用方交回来的很可能是一份过期副本。
1 failed, 45 deselected in 0.25s
```

与评审原文的复现逐字对应（`ManifestInvalidError … 回滚掉`）——期望的
`SourceChangedMidRun` 没有抛出，抛的是 `commit_stock` 深处的
`ManifestInvalidError`，说明比对被跳过、跑到了提交那一步才失败。已还原。

### I1（Important）· durability 测试改核对 fsync 的确切目录 fd

`test_copy_stock_fsyncs_directory_after_each_final_replace` 此前只断言
`os.replace` 之后紧跟的事件类型是 `"fsync"`，不查是哪个 fd——`fsync_dir
(pfd)` 换成 `fsync_dir(stg_fd)` 这种「fsync 了错的目录」照样能骗过去。
改法：`spy_replace` 额外记下这次 replace 用的 `dst_dir_fd`，断言随后那次
`fsync` 的 `dir_fd` 与它**逐一相等**。

```
$ find . -name "__pycache__" -exec rm -rf {} +
$ ../.venv/bin/python -m pytest tests/test_qmt_fetch.py -q -rs \
    -k test_copy_stock_fsyncs_directory_after_each_final_replace
1 passed, 45 deselected in 0.28s
```

**变异**：`_replace_part_to_final` 里 `fsync_dir(pfd)` → `fsync_dir(stg_fd)`：

```
E   AssertionError: fsync 的必须是 replace 实际用的那个目录 fd，不是别的目录
    （比如 staging 根）——实测事件序列
    [('replace', '...1分钟K线_前复权.csv', 14), ('fsync', 12),
     ('replace', '...日K线_前复权.csv', 14), ('fsync', 12), ('fsync', 12)]
E   assert 12 == 14
1 failed, 45 deselected in 0.24s
```
整份文件不 `-k`：`1 failed, 45 passed`——只有这一条变红。已还原
（`fsync_dir(pfd)`）；套件回到 46 passed。

### I2（Important）· 新增测试守住标记删除之后的 fsync

`_remove_inflight_marker` 的 `fsync_dir(stg_fd)` 此前没有任何测试盯着。
新增 `test_copy_stock_fsyncs_staging_root_after_marker_deletion`：
monkeypatch `os.unlink` + `qmt_fetch.fsync_dir` 记录事件序列，断言删标记
那次 `unlink`（`dir_fd=stg_fd`）之后紧跟的是对**同一个** `dir_fd` 的
`fsync`。

```
$ find . -name "__pycache__" -exec rm -rf {} +
$ ../.venv/bin/python -m pytest tests/test_qmt_fetch.py -q -rs \
    -k test_copy_stock_fsyncs_staging_root_after_marker_deletion
1 passed, 46 deselected in 0.22s
```

**变异**：删掉 `_remove_inflight_marker` 里的 `fsync_dir(stg_fd)`：

```
E   AssertionError: 删标记之后紧跟的必须是 fsync_dir，实测事件序列
    [('fsync', 14), ('fsync', 14), ('unlink_marker', 12)]
1 failed, 46 deselected in 0.26s
```
整份文件不 `-k`：`1 failed, 46 passed`——只有这一条变红。已还原；
套件回到 47 passed。

### I3（Important）· 成功重拷提交路径新增覆盖 + 订正文档误判

新增 `test_copy_stock_recopy_does_not_duplicate_pool_entry_or_regress_
cursor`：记录存在、本地目标同尺寸损坏（`TARGET_RECOPY`）、源不变（E3
场景），且 `universe_idx=0` **小于**已有 `cursor=5`（模拟其它股已经拉过、
游标走在前面——这是 `max()` 真正起作用、而不是与直接赋值给出同一个数的
场景）。断言提交成功、`pool_order` 不重复追加锚点、`cursor` 不倒退、
`committed_bytes = 旧值 + 本次真写盘字节`。同时把 `_apply_stock_records`
文档里「`max` 是防御性写法」订正为「承重构件」（评审指出这句话本身就是
误判的根源）。

```
$ find . -name "__pycache__" -exec rm -rf {} +
$ ../.venv/bin/python -m pytest tests/test_qmt_fetch.py -q -rs \
    -k test_copy_stock_recopy_does_not_duplicate_pool_entry_or_regress_cursor
1 passed, 47 deselected in 0.33s
```

**变异 A**（pool_order 去重判据删掉，无条件追加）：

```
E   qmt_manifest.ManifestInvalidError: pool_order[SH][1].code = '600000.SH' 在本层重复出现
1 failed, 47 deselected in 0.26s
```
整份文件：`1 failed, 47 passed`。已还原。

**变异 B**（`cursor[slot.market] = max(...)` 改成直接赋值 `universe_idx + 1`）：

```
E   qmt_manifest.ManifestInvalidError: per-stock 提交 会让 SH 层的 cursor 从 5 **倒退**到 1
1 failed, 47 deselected in 0.27s
```
整份文件：`1 failed, 47 passed`。已还原；套件回到 48 passed。

两组变异都与评审原文的复现逐字对应。

### I4（Important）· 异常分类不再只靠文档自称

⚠️ **本节的判断已被 fix round 2 · N2 撤销**——见下方 fix round 2 一节：
`invalid_stock_paths` 被判定为一个**第五个 failure reason**，而该全集已
被大 spec:492 与契约 D3 声明闭合，本节以下内容是历史记录，不是当前状态。

D1 拒绝改走既有的 `StockCopyFailed` 族（新增 `reason="invalid_stock_
paths"`），**不新增第四族**——`_validate_stock_paths` 捕获
`(PathDisciplineError, QmtSchemaError)` 后重新包装成
`StockCopyFailed("invalid_stock_paths", ...)`。模块 docstring / `copy_stock`
docstring / `StockCopyFailed` 类 docstring 均已更新：
- `StockCopyFailed.reason` 全集写全四个（`fetch_missing_file` /
  `fetch_copy_hash_mismatch` / `untracked_target_file` /
  `invalid_stock_paths`）；
- 明写裸 `TypeError`（`slot` 类型错误）与 `commit_stock` 标记写下之后
  可能抛出的 `ManifestInvalidError` 等**不属于**三族任何一个，且明写
  D6 的判据是**位置**（异常发生在标记写下之后）不是**类型**——调用方
  接到那一段抛出的任何异常都要按终止处理，不必检查类型。

新增两条测试把「文档这么说」落成「测试钉住」：
`test_copy_stock_invalid_stock_paths_is_a_stock_copy_failed_not_a_new_
family`（`reason == "invalid_stock_paths"` 且 `isinstance(..., StockCopy
Failed)`、非 `RunTerminated`/`PathEscapeError`）、
`test_copy_stock_bad_slot_type_error_is_not_part_of_any_declared_family`
（裸 `TypeError`、非三族任何一个）。

```
$ find . -name "__pycache__" -exec rm -rf {} +
$ ../.venv/bin/python -m pytest tests/test_qmt_fetch.py -q -rs \
    -k "test_copy_stock_invalid_stock_paths_is_a_stock_copy_failed_not_a_new_family or test_copy_stock_bad_slot_type_error_is_not_part_of_any_declared_family"
2 passed, 48 deselected in 0.27s
```

### 套件结果（fix round 1 完成后）

```
$ cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend"
$ find . -name "__pycache__" -exec rm -rf {} +
$ ../.venv/bin/python -m pytest tests/ -q -rs
1555 passed in 34.67s
```

Task 3 首次交付时是 1550 passed；fix round 1 净增 5 条测试（C2 回归钉 1 条
+ I2 新增 1 条 + I3 新增 1 条 + I4 新增 2 条），**1555 passed，skipped = 0**。
所有变异均已确认「单独跑该测试变红」+「整份文件跑只有这一条变红」+
「还原后套件复绿」，符合协调者要求的证据纪律。

六条 Minor 按协调者指示推迟到整支评审，本轮未动。

---

## Fix round 2（评审：确认 fix round 1 全部六条均已解决，但新提交自己带出
## 三个新问题，其中一条相对修复前是回归）

提交：`a457ef3`（N1+N2，代码+测试）。N3（本节）只改这份报告，不改代码，
不产生新提交（报告文件本身不进 git）。

### N1（Critical）· C2 换了查找键之后漏了一道门——回归

C2（fix round 1）把 `copy_stock` 找账本记录的键从 `(stock_code,
relative_path)` 改成 `(stock_code, period)`，堵住了“按路径查找不到记录”
这半个洞，但没有堵住新洞：换键之后，只要账本对某个周期确实有记录，代码
会把它原样交给四象限/落地前比对，**从不检查这条记录的 `relative_path`
是不是本次调用给的那一条**。评审复现了两个分支，且明确指出其中一个是
**相对 fix round 1 之前的回归**（fix round 1 之前跑同一个探针，得到的是
干净的 `StockCopyFailed untracked_target_file`；C2 的键改动之后同一探针
变成 `committed` 且账本指向一条盘上不存在的路径）：

- **SKIP 分支**：账本记录挂旧路径，新路径下的文件已经完好——四象限判
  `TARGET_SKIP`，旧记录被原样提交，指向一条盘上不存在的路径，新路径那
  份完好的文件反而没有任何记录。
- **COPY/RECOPY 分支、源没变**：账本记录挂旧路径，新路径下目标不存在，
  源内容与旧记录逐字相同——落地前比对（D5/D4 第 2 条）通过（因为真的没
  变），两个 final 落地、标记写下，`commit_stock` 才因“会把已提交的 files
  记录…回滚掉”拒绝——D6 要消灭的那个状态，外加一棵约 2 GiB 的 staging
  被判报废。

**修法**：在 `_validate_stock_paths` 之后、四象限判据之前新增一道统一的
门——只要 `records_in` 里某个周期的记录存在且它的 `relative_path` 与本次
调用给的路径不一致，直接 `raise StockCopyFailed("untracked_target_file",
...)`，两个分支都在写标记之前被拦下。

**为什么复用 `untracked_target_file` 而不是新开一档**：评审在 N2 里把
“闭合的 reason 全集”定了案（详见下方），本条门槛因此也不能凭空发一个新
reason；`untracked_target_file` 语义上恰好覆盖“这只股当前能看到的身份对
不上账本”这一整类（D2 原文覆盖的是“目标存在但无记录”，这里是“记录存在
但挂在别的身份上”，是同一类问题的另一种成因）——且评审自己描述“fix
round 1 之前的干净结果”正是这个 reason，等于确认了这是正确的落点。

两条新测试：`test_copy_stock_rejects_relocated_record_when_new_path_
already_matches`（SKIP 分支）、`test_copy_stock_rejects_relocated_record_
when_new_path_needs_fresh_copy`（COPY/RECOPY 分支）；`fix round 1 · C2`
遗留的 `test_copy_stock_detects_mismatch_when_existing_record_has_a_
different_relative_path`（“内容也变了”的变体）同样依赖这道新门，断言从
`SourceChangedMidRun` 改成了 `StockCopyFailed("untracked_target_file")`
——它现在在四象限之前就被拦，根本不会走到内容比对那一步。

**变异（先确认真的落进文件，再跑）**：

```
$ grep -n "raise StockCopyFailed(" qmt_fetch.py | sed -n '1p'   # 定位这道门
$ # 把判据短路成 `if False and rec is not None and rec.get(...) != rel:`
$ grep -n "_MUTATION（N1 回归验证）" qmt_fetch.py
qmt_fetch.py:643:        if False and rec is not None and rec.get("relative_path") != rel:  # _MUTATION（N1 回归验证）：门被去掉
$ python3 -c "import ast; ast.parse(open('qmt_fetch.py').read())" && echo "parses OK"
parses OK
$ find . -name "__pycache__" -exec rm -rf {} +
$ ls __pycache__ 2>&1; find . -name "*.pyc" | wc -l
ls: __pycache__: No such file or directory
0
$ ../.venv/bin/python -m pytest tests/test_qmt_fetch.py -q -rs \
    -k "test_copy_stock_rejects_relocated_record_when_new_path_already_matches or test_copy_stock_rejects_relocated_record_when_new_path_needs_fresh_copy"
2 failed, 50 deselected in 0.26s
```

两条失败分别是（逐字对应评审复现）：
```
Failed: DID NOT RAISE <class 'qmt_fetch.StockCopyFailed'>
```
（SKIP 分支——没加门时静默 `committed`）
```
qmt_manifest.ManifestInvalidError: per-stock 提交 会把已提交的 files 记录
('600000.SH', '1m', '1m/600000.SH_旧名字_1分钟K线_前复权.csv') **回滚**掉——
调用方交回来的很可能是一份过期副本。
```
（COPY/RECOPY 分支——落地前比对通过，撞在 `commit_stock` 上）

整份文件不 `-k`：`3 failed, 49 passed`——第三条是同样依赖这道门的
`test_copy_stock_detects_mismatch_when_existing_record_has_a_different_
relative_path`（fix round 1 遗留、本轮改了断言），没有其它测试受影响。
已还原（`grep -n "_MUTATION" qmt_fetch.py` 无命中），套件回到 52 passed。

### N2（Important）· `invalid_stock_paths` 是第五个 failure reason——撤销

评审核实：大 spec:492 把 failure 的 `reason` 全集钉死为四个（`fetch_
missing_file` / `fetch_copy_hash_mismatch` / `untracked_target_file` /
`fetch_interrupted_rollback`），契约 §5 的覆盖表没有点名这句话（点名式
覆盖，不点名即不覆盖，继续生效），且契约 D3 自己的取舍原文写着“不新增
failure reason（那份全集声明为闭合，加值要同步改 4c 报告 schema）”。
账本读侧不校验 `failures[].reason`，一个第五个取值不会被任何闸拦住，会
静默流进 manifest、落不进 4c 报告 schema 的任何一个桶。

**裁决**：fix round 1 · I4 把 D1 的两条路径拒绝折进 `StockCopyFailed
("invalid_stock_paths", ...)` 是错的，撤销。理由与裸 `TypeError`（`slot`
类型不对）同规格：这两条路径来自调用方（S4b），文件名解析出的代码与
`slot` 不符、或次序被互换，是**调用方违反了本函数的前置契约**，不是这只
股的事实，也不是环境变化。`_validate_stock_paths` 改回原样上抛
`QmtSchemaError`（不再 `try`/`except` 包装成 `StockCopyFailed`），不属于
三族任何一个。

改动：
- `_validate_stock_paths` 去掉 `try/except (PathDisciplineError,
  QmtSchemaError)` 包装，坏输入直接原样上抛（`QmtSchemaError` 或
  `PathDisciplineError`）；`PathDisciplineError` 的 import 因此不再需要，
  已删（round 1 加的，只在那段 `except` 里用过）。
- 模块 docstring / `StockCopyFailed` 类 docstring / `copy_stock` docstring
  三处同步订正（reason 全集写回三个 + 闭合原因；新增段落点名
  `QmtSchemaError`/`PathDisciplineError` 与裸 `TypeError` 同属“不属于任何
  一族”）。
- 测试：`test_copy_stock_invalid_stock_paths_is_a_stock_copy_failed_not_
  a_new_family`（fix round 1）替换成
  `test_copy_stock_invalid_stock_paths_belongs_to_no_family`（断言
  `QmtSchemaError`、非 `StockCopyFailed`/`RunTerminated`/`PathEscapeError`）；
  两条 D1 evidence-2 测试（次序互换 / 代码不符）断言从 `StockCopyFailed`
  改回 `QmtSchemaError`。

```
$ find . -name "__pycache__" -exec rm -rf {} +
$ ../.venv/bin/python -m pytest tests/test_qmt_fetch.py -q -rs \
    -k "test_copy_stock_invalid_stock_paths_belongs_to_no_family or test_copy_stock_rejects_swapped_period_order_before_marker_written or test_copy_stock_rejects_path_whose_filename_code_does_not_match_slot"
3 passed, 49 deselected in 0.26s
```

N2 没有单独要求变异（撤销一个分类判断，不是新增一条判据）；它与 N1 共用
同一次提交、同一次全量套件验证。

### N3（Important）· 订正没传到下一片会读的地方

两处评审点名的位置均已修：
- `classify_target` 的 docstring（`qmt_fetch.py:346` 附近）：把
  “按 `(stock_code, period, relative_path)` 查出来的那一条记录”改成
  “按 `(stock_code, period)` 查出来的那一条记录……不按 `relative_path` 查
  （fix round 1 · C2 订正……）”。
- 本报告“公开符号与签名（S4b 要接的接口）”一节：整节改写为 fix round 2
  为止的当前状态（`build_inflight_marker(slot, rel_1m, rel_daily)` 五字段
  形状、`copy_stock` 完整的异常清单），节首加了一句“本节维护到 fix round
  2 为止的最新状态……不要参考本节以外任何更早的草稿”。

**按评审要求，穷尽式 grep 了整份文件与整份报告**（不是只改点名的两处）：
- `qmt_fetch.py`：grep `market`、`按.*relative_path.*查`、`四个`——除了
  `classify_target` 那处已修的，其余全是当前语义正确的用法（`slot.market`
  用于 `pool_order`/`cursor` 记账，与标记形状无关；`四个字面量` 指的是
  `TARGET_*` 四个常量，与 `failures.reason` 全集无关）。
- `task-3-report.md`：grep 到三处历史遗留（决策 1 的原始三字段记录、
  fix round 1 · I4 整节、其中列出的 `invalid_stock_paths` 具体文字）——
  均已在原地加“⚠️ 已被 xxx 订正/撤销”的显式标注并说明现状指向哪一节，
  不删除历史记录本身（本仓“留副本、加标注”优于“悄悄改写”的既有惯例）。

本节不改代码、不产生新提交，只改报告；套件仍是 N1+N2 提交后的
**1557 passed，skipped = 0**。

被推迟到整支评审的两条 Minor（本轮未动）：在盘标记内容本身没有测试
（绕过构造函数直接写一份残缺 JSON，套件仍绿）；一条测试传字面量 `0` 当
文件描述符，`-1` 会更安全。

---

## Fix round 3（评审：N1/N2/N3 全部确认，包括两条评审自己额外补跑的变异
## ——把标记写下挪到 replace 之后单独证明顺序断言有判别力、把查找键退回
## relative_path 确认新门没有吞掉 C2 的钉子；N2 的裁决被核实为结构性成立、
## 不只是断言）

提交：`7b5f761`（纯文档，`git diff` 逐行核对过全部落在三引号 docstring
内，无一行可执行代码改动）。

### 遗留两条同族问题：闭合集的穷尽性断言本身写错了

`StockCopyFailed` 类文档（`qmt_fetch.py:89-100`）说「这个全集是闭合的」，
冒号后却只列了三个值，随后又说违规是「第五个取值」——**漏列了第四个
`fetch_interrupted_rollback`**，而同一份文件里 `_validate_stock_paths`
的判据注释与大 spec:492 都正确地列了四个。这句话是 fix round 2 才改成
现在这个措辞的（round 1 原文是「本模块目前产生四个」，那是一句关于**本
模块**的陈述，不是关于**全局闭合集**的陈述——两者的外延本来就不同，
round 2 把「本模块产生几个」误写成了「全集有几个」）。要紧的是
`fetch_interrupted_rollback` 恰好是 **S4b** 崩溃恢复要产生的那个值，而
S4b 正是这个导出类的读者。

修法：先把闭合集的四个值完整列出，再单独一段说明「本模块只产生其中
三个……第四个由 S4b 的崩溃恢复产生」，两件事分开说，不再混在一起。模块
顶部 docstring 原文用的是「含」（非穷尽措辞，评审说明写“对，可留可改，
我的判断”），为保持同一份文件内两处对同一件事的说法一致，一并对齐补上
第四个的去向说明。

`RunTerminated` 类文档另一处（`qmt_fetch.py:109-114`，Minor，同一个提交
里顺手修）仍是 fix round 1 之前留下的未来时——「本片只有
`MaxBytesExhausted` 一个成员；Task 3 会补第二个成员」，而
`SourceChangedMidRun` 就在八行之下已经声明。改成直陈现状：「两个成员：
`MaxBytesExhausted`……与 `SourceChangedMidRun`……」。评审点明：这处遗留
不是本轮引入的，是**穿过了 N3 那次扫描**——N3 当时扫的是“三字段标记”与
“relative_path 当查找键”两类具体措辞，没有覆盖“未来时描述已完成的工作”
这一类，是扫描覆盖面本身的缺口，不是漏看。

```
$ /usr/bin/git diff backend/qmt_fetch.py | head -1   # 只有这一个文件改动
diff --git a/backend/qmt_fetch.py b/backend/qmt_fetch.py
$ find . -name "__pycache__" -exec rm -rf {} +
$ cd backend && ../.venv/bin/python -m pytest tests/ -q -rs
1557 passed in 34.31s
```

### 关于 `grep` 别名的纪律订正（评审 + 协调者共同发现）

本 shell 里的 `grep`是包了 `ugrep -G --ignore-files` 的函数，**会遵守
`.gitignore`**——而 `.superpowers/` 正在 `.gitignore` 里，账本/brief/
报告/评审快照全在那棵目录下。**但只在“靠 `-r` 递归发现文件”这一步会漏**：
本轮实测确认，`grep <file>`（显式传一个具体文件路径，不靠 `-r` 遍历）与
`/usr/bin/grep <file>` 结果逐字相同（都是 12 处命中）——受影响的只是**用
别名 grep 去发现“目录里还有哪些文件提到某个词”**这一步，不是“对着已知的
某个文件数命中数”这一步。fix round 1/2 里我对 `task-3-report.md` 的检查
用的都是显式文件路径，未受影响；但为了不留死角，本轮用
`/usr/bin/grep -rl` 递归重扫了整个
`.superpowers/sdd/2026-09-19-qmt-4b-s4a-impl/` 目录，找到三类历史提法：

- `review-*.diff`（`f8af7adf..6c1b9e24` / `6c1b9e24..615e50f7` /
  `615e50f7..a457ef33`）：评审工具自己产出的**只读快照**，是“对着哪次
  diff 跑的审计凭据”，不是文档；改它等于伪造审计记录，不属于本任务范围。
- `progress.md`：协调者自己维护的 SDD 台账（原文自己写着“控制者亲自核”），
  不是我该主动改的文件。
- `task-2-report.md`：**另一个已经关闭的任务**（Task 2）在它自己完工时
  写下的报告，命中的那句话（`(stock_code, period, relative_path)` 查出来
  的记录）描述的是 Task 2 交付时刻的事实，早于 C2 的存在——不是这一轮该
  回头改写别的任务历史的理由。
- `task-3-report.md`：本文件自己——已在 fix round 2 逐一标注过
  「⚠️ 已被……订正/撤销」，本轮 `/usr/bin/grep` 复核逐条对照，未发现新的
  未标注残留。

本节不改代码，`git diff` 与上方 fix round 3 代码小节共享同一次提交
`7b5f761`。套件保持 **1557 passed，skipped = 0**。

被推迟到整支评审的项目（本轮未动，评审明确列出）：`PathDisciplineError`
那条拒绝路径没有专门测试；在盘标记内容本身没有测试（绕过构造函数写一份
残缺 JSON）；一条测试传字面量 `0` 当文件描述符；本片新增的门给 S4b 加了
一条契约交接单未点名的读侧约束，协调者会自己把它写进契约，不需要我碰
spec。
