# PR 7a 验收清单（C1b 值类型 + revision 单调性测试）

> 验收人：用户（非 coder 可执行）
> Spec 锚点：`kline_trainer_modules_v1.4.md` §C1b L957-1131 + L1209
> Plan：`docs/superpowers/plans/2026-05-05-pr7a-c1b-values-revision.md`

## 范围
本次改动新增 1 个 Swift 文件（C1b 状态值类型 + 部分 reducer），1 个测试文件（42 tests），不动任何 production 实现 / spec / Models。drawing FSM、27 格矩阵、漂移、cross-session guard、animator 集成全部留 PR7b1/7b2/7b3。

> **路径假设：** 以下命令路径全部假设你**在 PR7a worktree 内**跑（执行阶段）。若 PR 已 merge 到 main，请把所有路径前缀 `.claude/worktrees/pr7a-c1b-values-revision/` 替换为主仓库 `/Users/maziming/Coding/Prj_Kline trainer/`，再跑相同命令。

## 一、编译通过

| # | 动作 | 预期 | 通过判定 |
|---|---|---|---|
| 1 | 终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/pr7a-c1b-values-revision" && swift build --package-path ios/Contracts 2>&1 \| tail -3` | 输出含 `Build complete!`，无红色 error 行 | 看到 `Build complete!` = ✅ |
| 2 | 终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/pr7a-c1b-values-revision" && swift build --package-path ios/Contracts -c release 2>&1 \| tail -3` | 输出含 `Build complete!`（release 编译成功 = reducer 不依赖 DEBUG）| 看到 `Build complete!` = ✅ |

## 二、新增测试 0 failures

| # | 动作 | 预期 | 通过判定 |
|---|---|---|---|
| 3 | 终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/pr7a-c1b-values-revision" && swift test --package-path ios/Contracts --filter ReducerTests 2>&1 \| tail -10` | 输出含 `with 0 failures` 或 `passed` | 含 `with 0 failures` 或 `passed` = ✅ |

## 三、不影响 PR #37-46 既有测试

| # | 动作 | 预期 | 通过判定 |
|---|---|---|---|
| 4 | 终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/pr7a-c1b-values-revision" && swift test --package-path ios/Contracts 2>&1 \| tail -30` | 全部 suite 全过；输出含 `with 0 failures` 或 `passed`，**不**含 `Test failed` / `failed:` 字样 | 含 `with 0 failures` 或 `passed` 且无 failed 字样 = ✅ |

## 四、生产代码 0 改动 + spec 0 改动 + Models 0 改动

| # | 动作 | 预期 | 通过判定 |
|---|---|---|---|
| 5 | 终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/pr7a-c1b-values-revision" && git diff main..HEAD --name-only -- 'ios/Contracts/Sources/KlineTrainerPersistence/'` | 输出为空字符串 | 输出空 = ✅ |
| 6 | 终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/pr7a-c1b-values-revision" && git diff main..HEAD --name-only -- 'kline_trainer_modules_v1.4.md' 'kline_trainer_plan_v1.5.md'` | 输出为空字符串 | 输出空 = ✅ |
| 7 | 终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/pr7a-c1b-values-revision" && git diff main..HEAD --name-only -- 'ios/Contracts/Sources/KlineTrainerContracts/Models.swift' 'ios/Contracts/Sources/KlineTrainerContracts/AppError.swift' 'ios/Contracts/Sources/KlineTrainerContracts/AppState.swift' 'ios/Contracts/Sources/KlineTrainerContracts/Geometry/' 'ios/Contracts/Sources/KlineTrainerContracts/Theme/' 'ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/'` | 输出为空字符串 | 输出空 = ✅ |

## 五、新增文件路径正确

| # | 动作 | 预期 | 通过判定 |
|---|---|---|---|
| 8 | 终端执行 `ls "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/pr7a-c1b-values-revision/ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift"` | 输出文件路径，非 No such file | 列出文件 = ✅ |
| 9 | 终端执行 `ls "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/pr7a-c1b-values-revision/ios/Contracts/Tests/KlineTrainerContractsTests/ReducerTests.swift"` | 输出文件路径 | 列出文件 = ✅ |

## 六、`revision` 字段访问控制 = `private(set)`

| # | 动作 | 预期 | 通过判定 |
|---|---|---|---|
| 10 | 终端执行 `grep -c "public private(set) var revision: UInt64" "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/pr7a-c1b-values-revision/ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift"` | 输出 `1` | 数字 = 1 = ✅ |

## 七、Drawing-action 占位带 PR7b1 标记

| # | 动作 | 预期 | 通过判定 |
|---|---|---|---|
| 11 | 终端执行 `grep -c "PR7b1 scope" "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/pr7a-c1b-values-revision/ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift"` | 输出 ≥ 1 | 数字 ≥ 1 = ✅（占位分支必须带可 grep 标记）|

## 失败兜底
任何步骤通过条件不满足，**不要继续合并** —— 把终端完整输出贴给 Claude 让它修。
