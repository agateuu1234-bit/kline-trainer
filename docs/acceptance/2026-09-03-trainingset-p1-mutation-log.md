# 切片一 · P1 变异验证记录

> spec：`docs/superpowers/specs/2026-09-01-trainingset-timestamp-semantics-design.md` §4
> 判据：每组必须写明**红的是哪一条测试**（⛔ 只写「已验证」不算）
> 复原：⛔ 不用 `git checkout <file>`（会静默抹掉未提交改动）；用手工改回（改前先抄下原文）
>
> 执行环境：`backend/`（分支 `feat/trainingset-app-contract-fix`，HEAD `58a8773`）；
> 解释器 `/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3`（本 worktree 无 `.venv`）；
> 每组变异前后均先 `find . -name '__pycache__' -type d -exec rm -rf {} +` 再
> `PYTHONDONTWRITEBYTECODE=1 python3 -m pytest tests/ -q`。基线与最终均为 **1118 passed / 0 failed / 0 skipped**。

| 变异 | 改了什么 | 红的是哪一条测试 | 结论 |
|---|---|---|---|
| **B1** | `assign_global_indices` 循环体：`upper = period_end(_open, period)` 整体改回逐字对齐重构前（`08d5058^`）的公式 `nxt = opens[i+1] if i+1<len(opens) else None; upper = (nxt-1) if nxt is not None else three_dts[-1]`（全部周期不分流） | `test_assign_intraday_crosses_lunch_and_day_boundary`、`test_assign_end_global_index_interior_historical_trailing`、`test_assign_weekly_hole_uses_calendar_period_end` | **符合预期**（与 brief 逐字一致）|
| **B2** | `period_end` 分流条件反过来：`if period in _CLOSE_LABELLED:` → `if period not in _CLOSE_LABELLED:`（其余不变） | 实测 **42 个用例红**，含 brief 预期的两条 `test_assign_daily_unchanged_by_the_split`、`test_assign_monthly_realistic_scale`，另外还波及 `test_generate_training_sets.py` 里几乎全部 `period_end`/`assign_global_indices`/`assemble_from_windows` 用例 + `test_b2_reconnect_integration.py` 全部 21 条 + `test_qmt_e2e_generation.py` 1 条 | **符合预期且更强**（超预期的原因见下方说明，非判据不成立）|
| **B3** | `assign_global_indices` 循环体加回分流：`if period in _CLOSE_LABELLED: upper = period_end(...)` 否则走 B1 的「下一根−1」老公式（日内保持新式，仅开盘侧退化） | `test_assign_weekly_hole_uses_calendar_period_end`（brief 预期）+ `test_assign_end_global_index_interior_historical_trailing`（`_index_windows()` fixture 里 monthly 是开盘侧、同样被 B3 波及，其 `[1,5]` 老值与当前断言 `[5,5]` 不符） | **符合预期且更强**（daily 按文档所述新旧公式在其 fixture 上巧合相同，未红，与 spec §4.1① 一致）|
| **B4** | `period_end` 末尾构造 `_dt.datetime(...)` 的 `tzinfo=_SHANGHAI` → `tzinfo=_dt.timezone.utc`（只这一处，全文件唯一出现点） | `test_period_end_daily_is_end_of_that_trading_day`、`test_period_end_weekly_is_that_weeks_sunday`、`test_period_end_monthly_is_last_moment_of_that_month` | **符合裁定二的更正**：`test_assign_monthly_realistic_scale` **确认未红**（3 根仍是 `[0,0,7]`，与用户实测预判一致），无需停下报告 |
| **B5** | `period_end` 收盘标注分支：`return int(datetime_epoch)` → `return int(datetime_epoch) - 1140` | `test_assign_intraday_crosses_lunch_and_day_boundary`（brief 预期）+ `test_assign_3m_global_index_and_end_equal`、`test_assign_end_global_index_interior_historical_trailing`、`test_period_end_close_labelled_returns_input_unchanged`、`test_assign_daily_unchanged_by_the_split`（因为该分支同时覆盖 3m 自身，偏移把 3m 自身的 identity 映射也破坏了） | **符合预期且更强** |
| **B6** | `period_end` 的 `elif period == "weekly": last = _week_end_date(datetime_epoch)` → `last = d`（走 daily 算法） | `test_period_end_weekly_is_that_weeks_sunday`、`test_assign_weekly_hole_uses_calendar_period_end` | **符合预期**（与 brief 逐字一致）|
| **B7** | `_CLOSE_LABELLED = frozenset({"3m","15m","60m"})` → 加入 `"daily"` | `test_assign_daily_unchanged_by_the_split`（brief 预期）+ `test_period_end_daily_is_end_of_that_trading_day`（daily 被当收盘标注后，`period_end` 对 daily 直接返回输入本身、不再算到 23:59:59） | **符合预期且更强** |
| **B9** | `SCHEMA_VERSION = 2` → `= 1`（DDL 字面量段落 `PRAGMA user_version = 2;` 保持不动） | `test_build_sqlite_user_version_meta_and_rowcount`（`PRAGMA user_version` 实际写入的是 DDL 字面量 `2`，断言对比的 `SCHEMA_VERSION` 变量却是 `1` ⇒ `2 == 1` 断言失败） | **符合预期**（与 brief 逐字一致）|
| **B34** | `zip_and_hash` body 改回重构前（`08fd4e7^`）写法：去掉固定 `ZipInfo`/`date_time`/`external_attr`，改用 `with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf: zf.write(db_path, arcname=db_path.name)` | `test_zip_and_hash_is_deterministic_across_runs`（`h1='9f2b4648'` ≠ `h2='bd732af3'`，随 mtime 变化） | **符合预期**（与 brief 逐字一致）|
| **B66** | `select_period_window` 函数体内新增一份嵌套闭包 `def _week_end_date(open_epoch): ...`（逐字对齐重构前 `6f9b8e9^` 版本），**模块级 `_week_end_date` 保留不动**（否则 `period_end` 里对模块级 `_week_end_date` 的调用会因 `NameError` 炸掉大批无关用例，偏离本条要测的「两份实现漂移」这个具体缺陷） | `test_week_end_date_is_module_level_and_shared`（`hasattr` 通过，但 `monkeypatch.setattr(g, "_week_end_date", spy)` 后 `select_period_window` 走的是自己函数体内的闭包、spy 未被调用 ⇒ `assert calls` 失败） | **符合预期**（唯一红、无旁及，与 brief 逐字一致）|
| **B1+B3 组合** | 同时段落施加 B1 与 B3。⚠️ **说明**：B1 的定义（spec §4 line 484「删掉语义分流，全部走下一根−1」）在作用范围上是 B3（spec §4 line 486「仅开盘侧改回下一根−1」）的**超集**——二者都落在 `assign_global_indices` 同一处代码，B1 把「开盘侧 + 收盘标注侧」都退化成老公式，B3 只退化开盘侧。两者「同时施加」在这段代码上唯一自洽的合并态就是 B1 的全量退化版本（它已完整包含 B3 描述的效果）。据此把组合变异实现为 B1 那份改动，验证组合态下依旧有红、且红的用例包含 B1 单独施加时与 B3 单独施加时的**公共项** `test_assign_weekly_hole_uses_calendar_period_end` | `test_assign_end_global_index_interior_historical_trailing`、`test_assign_intraday_crosses_lunch_and_day_boundary`、`test_assign_weekly_hole_uses_calendar_period_end`（与 B1 单独施加时完全一致；`test_assign_weekly_hole_uses_calendar_period_end` 同时也是 B3 单独施加时的红名单成员，证明两条变异不互相掩盖） | **符合预期** —— 组合下仍有测试红，未出现「两条变异互相抵消回到绿」的情况 |

## 逐条实测记录（含实际 pytest 输出片段）

以下每组均按「抄原文 → 改 → 清 `__pycache__` → 跑 → 记录 FAILED 行 → 手工改回 → 再清缓存再跑一次确认恢复全绿」执行，命令统一为：

```bash
cd backend && find . -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; \
  PYTHONDONTWRITEBYTECODE=1 "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/ -q
```

### B1

改（`backend/generate_training_sets.py`，`assign_global_indices` 内）：

```diff
-        for _open in opens:
-            upper = period_end(_open, period)
+        for i, _open in enumerate(opens):
+            nxt = opens[i + 1] if i + 1 < len(opens) else None
+            upper = (nxt - 1) if nxt is not None else three_dts[-1]
             j = bisect_right(three_dts, upper) - 1
             egi.append(max(0, min(j, n3 - 1)))
```

实际输出：

```
FAILED tests/test_generate_training_sets.py::test_assign_end_global_index_interior_historical_trailing
FAILED tests/test_generate_training_sets.py::test_assign_intraday_crosses_lunch_and_day_boundary
FAILED tests/test_generate_training_sets.py::test_assign_weekly_hole_uses_calendar_period_end
3 failed, 1115 passed in 37.94s
```

复原后：`1118 passed in 37.09s`；`git status --short backend/` 无输出。

### B2

改（`period_end` 分流条件）：

```diff
-    if period in _CLOSE_LABELLED:
+    if period not in _CLOSE_LABELLED:
         return int(datetime_epoch)
     d = trading_date(datetime_epoch)
```

实际输出（节选 —— 42 个失败用例覆盖 `test_generate_training_sets.py`、`test_b2_reconnect_integration.py` 全部、`test_qmt_e2e_generation.py`）：

```
FAILED tests/test_b2_reconnect_integration.py::test_real_sweep_registers_at_least_one_training_set
FAILED tests/test_b2_reconnect_integration.py::test_registered_zip_exists_and_hash_matches
... (共 21 条 test_b2_reconnect_integration.py 全部用例)
FAILED tests/test_generate_training_sets.py::test_assign_3m_global_index_and_end_equal
FAILED tests/test_generate_training_sets.py::test_assign_non_min_period_global_index_is_null
FAILED tests/test_generate_training_sets.py::test_assign_end_global_index_interior_historical_trailing
FAILED tests/test_generate_training_sets.py::test_assign_end_global_index_monotonic_and_in_range
FAILED tests/test_generate_training_sets.py::test_build_sqlite_user_version_meta_and_rowcount
FAILED tests/test_generate_training_sets.py::test_build_sqlite_integer_columns_are_int_not_float
FAILED tests/test_generate_training_sets.py::test_assemble_from_windows_produces_zip_and_matching_hash
FAILED tests/test_generate_training_sets.py::test_assemble_from_windows_filename_is_code_underscore_start
FAILED tests/test_generate_training_sets.py::test_assemble_from_windows_writes_all_periods_into_sqlite
FAILED tests/test_generate_training_sets.py::test_assemble_from_windows_leaves_only_zip_in_output_dir
FAILED tests/test_generate_training_sets.py::test_period_end_close_labelled_returns_input_unchanged
FAILED tests/test_generate_training_sets.py::test_period_end_daily_is_end_of_that_trading_day
FAILED tests/test_generate_training_sets.py::test_period_end_weekly_is_that_weeks_sunday
FAILED tests/test_generate_training_sets.py::test_period_end_monthly_is_last_moment_of_that_month
FAILED tests/test_generate_training_sets.py::test_period_end_rejects_unknown_period
FAILED tests/test_generate_training_sets.py::test_assign_intraday_crosses_lunch_and_day_boundary
FAILED tests/test_generate_training_sets.py::test_assign_daily_unchanged_by_the_split
FAILED tests/test_generate_training_sets.py::test_assign_monthly_realistic_scale
FAILED tests/test_generate_training_sets.py::test_assign_weekly_hole_uses_calendar_period_end
FAILED tests/test_qmt_e2e_generation.py::test_real_bundle_drives_real_generate_batch_to_zip
42 failed, 1076 passed in 32.57s
```

**为什么比 brief 预期（2 条）大得多**：反转后 `if period not in _CLOSE_LABELLED` 对 `period="3m"/"15m"/"60m"` 不再提前 return，落入 `if period=="daily"/elif "weekly"/elif "monthly"/else: raise ValueError` 分支，三者都不匹配 → 直接 `raise ValueError`。任何调用 `period_end` 传入 3m/15m/60m 的路径（`assign_global_indices` 对每个窗口都会调用）都会因异常整条用例报错，而不仅仅是断言值错——这是**更强**的判别力，brief 列出的两条只是这批红里的一部分，`test_assign_daily_unchanged_by_the_split` 与 `test_assign_monthly_realistic_scale` 均在实际红名单内，无不符情形。

复原后：`1118 passed in 37.04s`；`git status --short backend/` 无输出。

### B3

改：

```diff
-        for _open in opens:
-            upper = period_end(_open, period)
+        for i, _open in enumerate(opens):
+            if period in _CLOSE_LABELLED:
+                upper = period_end(_open, period)
+            else:
+                nxt = opens[i + 1] if i + 1 < len(opens) else None
+                upper = (nxt - 1) if nxt is not None else three_dts[-1]
             j = bisect_right(three_dts, upper) - 1
             egi.append(max(0, min(j, n3 - 1)))
```

实际输出：

```
FAILED tests/test_generate_training_sets.py::test_assign_end_global_index_interior_historical_trailing
FAILED tests/test_generate_training_sets.py::test_assign_weekly_hole_uses_calendar_period_end
2 failed, 1116 passed in 37.30s
```

`test_assign_end_global_index_interior_historical_trailing` 的失败点：`_index_windows()` fixture 里 `monthly=[-100,20]`，用老公式手算得 `[1,5]`（`i=0`: `nxt=20, upper=19` → `bisect_right([0,10,20,30,40,50],19)-1=1`；`i=1`: 末根 `upper=three_dts[-1]=50` → `5`），与当前断言 `[5,5]` 不符，属开盘侧被 B3 波及、**符合公式**、非异常。`daily` 分支（`[0,50]`）在该场景未被断言，`test_assign_daily_unchanged_by_the_split` 未红（daily 在其专用 fixture 上新老公式巧合相同，见 spec §4.1①），与 brief 一致未列出。

复原后：`1118 passed in 36.97s`；`git status --short backend/` 无输出。

### B4

改（`period_end` 末尾唯一一处 `tzinfo=`）：

```diff
-                            tzinfo=_SHANGHAI).timestamp())
+                            tzinfo=_dt.timezone.utc).timestamp())
```

实际输出：

```
FAILED tests/test_generate_training_sets.py::test_period_end_daily_is_end_of_that_trading_day
FAILED tests/test_generate_training_sets.py::test_period_end_weekly_is_that_weeks_sunday
FAILED tests/test_generate_training_sets.py::test_period_end_monthly_is_last_moment_of_that_month
3 failed, 1115 passed in 37.12s
```

**裁定二核实结果**：`test_assign_monthly_realistic_scale` **确认未出现在红名单里**（该测试的三根 monthly 在 UTC 偏移下仍是 `[0, 0, 7]` —— 月末整体晚 8 小时，但相对 3m 轴首/轴末的相对位置不变），与用户的实测预判完全一致，**无需停下报告**。

复原后：`1118 passed in 37.34s`；`git status --short backend/` 无输出。

### B5

改（`period_end` 收盘标注分支）：

```diff
     if period in _CLOSE_LABELLED:
-        return int(datetime_epoch)
+        return int(datetime_epoch) - 1140
```

实际输出：

```
FAILED tests/test_generate_training_sets.py::test_assign_3m_global_index_and_end_equal
FAILED tests/test_generate_training_sets.py::test_assign_end_global_index_interior_historical_trailing
FAILED tests/test_generate_training_sets.py::test_period_end_close_labelled_returns_input_unchanged
FAILED tests/test_generate_training_sets.py::test_assign_intraday_crosses_lunch_and_day_boundary
FAILED tests/test_generate_training_sets.py::test_assign_daily_unchanged_by_the_split
5 failed, 1113 passed in 37.28s
```

比 brief 预期（1 条）更多的原因：该分支同时覆盖 `period="3m"` 自身（3m 也在 `_CLOSE_LABELLED` 里），固定偏移把 `3m` 自身的 `end_global_index` 恒等映射也破坏了，波及范围更广，**属更强判别力**，brief 预期的 `test_assign_intraday_crosses_lunch_and_day_boundary` 在实际红名单内。

复原后：`1118 passed in 37.07s`；`git status --short backend/` 无输出。

### B6

改：

```diff
     elif period == "weekly":
-        last = _week_end_date(datetime_epoch)
+        last = d
```

实际输出：

```
FAILED tests/test_generate_training_sets.py::test_period_end_weekly_is_that_weeks_sunday
FAILED tests/test_generate_training_sets.py::test_assign_weekly_hole_uses_calendar_period_end
2 failed, 1116 passed in 38.49s
```

复原后：`1118 passed in 36.94s`；`git status --short backend/` 无输出。

### B7

改：

```diff
-_CLOSE_LABELLED = frozenset({"3m", "15m", "60m"})
+_CLOSE_LABELLED = frozenset({"3m", "15m", "60m", "daily"})
```

实际输出：

```
FAILED tests/test_generate_training_sets.py::test_period_end_daily_is_end_of_that_trading_day
FAILED tests/test_generate_training_sets.py::test_assign_daily_unchanged_by_the_split
2 failed, 1116 passed in 37.11s
```

比 brief 预期（1 条）多出 `test_period_end_daily_is_end_of_that_trading_day`：`daily` 被并入收盘标注后 `period_end` 对其直接原样返回（不再算到当日 23:59:59），该测试直接断言 23:59:59 ⇒ 同步变红，属同一缺陷的另一处直接体现。

复原后：`1118 passed in 37.17s`；`git status --short backend/` 无输出。

### B9

改：

```diff
-SCHEMA_VERSION = 2
+SCHEMA_VERSION = 1
```

（DDL 字面量段落 `_TRAINING_SET_DDL` 里的 `PRAGMA user_version = 2;` 未动。）

实际输出：

```
FAILED tests/test_generate_training_sets.py::test_build_sqlite_user_version_meta_and_rowcount
1 failed, 1117 passed in 37.11s
```

失败点：`conn.execute("PRAGMA user_version").fetchone()[0] == SCHEMA_VERSION` → `2 == 1` 断言失败（DDL 写入的是字面量 `2`，比对变量已被改成 `1`）。

复原后：`1118 passed in 37.16s`；`git status --short backend/` 无输出。

### B34

改（`zip_and_hash` 函数体）：

```diff
-    info = zipfile.ZipInfo(filename=db_path.name, date_time=(1980, 1, 1, 0, 0, 0))
-    info.compress_type = zipfile.ZIP_DEFLATED
-    info.external_attr = 0o644 << 16          # 固定权限位，避免 umask 影响字节
-    with zipfile.ZipFile(zip_path, "w") as zf:
-        zf.writestr(info, db_path.read_bytes())
+    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
+        zf.write(db_path, arcname=db_path.name)
     return crc32_hex(zip_path.read_bytes())
```

实际输出：

```
FAILED tests/test_generate_training_sets.py::test_zip_and_hash_is_deterministic_across_runs
1 failed, 1117 passed in 37.49s
```

失败细节：`h1='9f2b4648' != h2='bd732af3'`（`AssertionError: CRC32 随 mtime 变化 ⇒ 确定性不成立`）。

复原后：`1118 passed in 37.35s`；`git status --short backend/` 无输出。

### B66

改（`select_period_window` 函数体内新增一份嵌套闭包，模块级 `_week_end_date` 保留不动）：

```diff
+    def _week_end_date(open_epoch):
+        d = trading_date(open_epoch)
+        return d + _dt.timedelta(days=(6 - d.weekday()))   # 该周周日
+
     if period == "weekly":
         ae_date = trading_date(after_end)
```

实际输出：

```
FAILED tests/test_generate_training_sets.py::test_week_end_date_is_module_level_and_shared
1 failed, 1117 passed in 36.68s
```

失败点：`assert calls, "select_period_window 没有调用模块级 _week_end_date（说明它还在用内部闭包）"` —— `calls == []`。
⚠️ 实现取舍说明：若严格按「挪回」字面理解为**删除**模块级定义、只留函数体内一份，会导致模块级 `period_end`（对 weekly 调用 `_week_end_date`）直接 `NameError`，波及一大批与本条缺陷（「两份实现漂移」）无关的用例，观测量变得不精确。改为**新增一份重复的嵌套闭包、模块级原样保留**，精确复现 spec 该条要防的具体场景（`select_period_window` 内部有嵌套闭包 ⇒ `monkeypatch` 打的桩收不到调用），红名单与 brief 预期完全一致、无旁及。

复原后：`1118 passed in 37.30s`；`git status --short backend/` 无输出。

### B1+B3 组合

改：同 B1（`assign_global_indices` 循环体整体退化为「下一根−1」，见上）。

实际输出：

```
FAILED tests/test_generate_training_sets.py::test_assign_end_global_index_interior_historical_trailing
FAILED tests/test_generate_training_sets.py::test_assign_intraday_crosses_lunch_and_day_boundary
FAILED tests/test_generate_training_sets.py::test_assign_weekly_hole_uses_calendar_period_end
3 failed, 1115 passed in 37.29s
```

`test_assign_weekly_hole_uses_calendar_period_end` 同时是 B1 单独施加、B3 单独施加两份红名单的**公共项**，组合态下依旧红 ⇒ 两条变异未互相掩盖。

复原后：`1118 passed in 37.29s`；`git status --short backend/` 无输出。

## 最终验证

```bash
cd backend && find . -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; \
  PYTHONDONTWRITEBYTECODE=1 "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/ -q
```

```
1118 passed in 37.35s
```

```bash
git status --short backend/
```

```
(无输出)
```

`git diff --stat HEAD -- backend/` 同样无输出，确认 10 组独立变异 + 1 组组合变异全部复原干净，未在 `backend/` 留下任何残余改动。
