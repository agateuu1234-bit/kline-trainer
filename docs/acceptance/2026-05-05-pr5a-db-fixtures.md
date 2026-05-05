# PR 5a 验收清单（DB-domain 测试 fixture）

> 验收人：用户（非 coder 可执行）
> Spec 锚点：`kline_trainer_modules_v1.4.md` §11.3 line 2195-2200
> Plan：`docs/superpowers/plans/2026-05-05-pr5a-db-fixtures.md`

## 范围
本次改动新增 5 个测试用 in-memory fake：
- 4 个数据库相关 fake（成交记录 / 待续训练 / 设置 / 验收日志）
- 1 个训练组数据库读取器 fake（PreviewTrainingSetReader + 配套 PreviewTrainingSetDBFactory）

## 一、编译通过

| # | 动作 | 预期 | 通过判定 |
|---|---|---|---|
| 1 | 终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr5a/db-fixtures" && swift build --package-path ios/Contracts 2>&1 \| tail -3` | 输出含 `Build complete!`，无红色 error 行 | 看到 `Build complete!` = ✅ |

## 二、测试全过

| # | 动作 | 预期 | 通过判定 |
|---|---|---|---|
| 2 | 终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr5a/db-fixtures" && swift test --package-path ios/Contracts 2>&1 \| tail -5` | 末尾若干行含 `Test run with N tests in M suites passed` 或 `Executed N tests, with 0 failures` | 输出含 `with 0 failures` 或 `passed` = ✅ |

## 三、新增测试 0 failures

| # | 动作 | 预期 | 通过判定 |
|---|---|---|---|
| 3 | 终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr5a/db-fixtures" && swift test --package-path ios/Contracts --filter InMemoryDBFakesTests 2>&1 \| tail -3` | 输出 `Executed N tests, with 0 failures` | 输出含 `with 0 failures` = ✅ |
| 4 | 终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr5a/db-fixtures" && swift test --package-path ios/Contracts --filter PreviewTrainingSetReaderTests 2>&1 \| tail -3` | 输出 `Executed N tests, with 0 failures` | 输出含 `with 0 failures` = ✅ |

## 四、不影响 PR #37-44 既有测试

| # | 动作 | 预期 | 通过判定 |
|---|---|---|---|
| 5 | 终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr5a/db-fixtures" && swift test --package-path ios/Contracts --filter TickEngineTests 2>&1 \| tail -3` | 全过 | 输出含 `with 0 failures` = ✅ |
| 6 | 终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr5a/db-fixtures" && swift test --package-path ios/Contracts --filter GeometryTests 2>&1 \| tail -3` | 全过 | 输出含 `with 0 failures` = ✅ |
| 7 | 终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr5a/db-fixtures" && swift test --package-path ios/Contracts --filter ThemeTests 2>&1 \| tail -3` | 全过 | 输出含 `with 0 failures` = ✅ |
| 8 | 终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr5a/db-fixtures" && swift test --package-path ios/Contracts --filter SettingsStoreProductionTests 2>&1 \| tail -3` | 全过 | 输出含 `with 0 failures` = ✅ |
| 9 | 终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr5a/db-fixtures" && swift test --package-path ios/Contracts --filter TrainingSessionCoordinatorTests 2>&1 \| tail -3` | 全过 | 输出含 `with 0 failures` = ✅ |
| 10 | 终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr5a/db-fixtures" && swift test --package-path ios/Contracts --filter AcceptanceJournalDAOContractTests 2>&1 \| tail -3` | 全过 | 输出含 `with 0 failures` = ✅ |

## 五、生产代码 0 改动

| # | 动作 | 预期 | 通过判定 |
|---|---|---|---|
| 11 | 终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr5a/db-fixtures" && git diff main..HEAD --name-only -- 'ios/Contracts/Sources/KlineTrainerPersistence/'` | 输出为空字符串 | 输出空 = ✅ |
| 12 | 终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr5a/db-fixtures" && git diff main..HEAD --name-only -- 'ios/Contracts/Sources/KlineTrainerContracts/Persistence/'` | 输出为空字符串 | 输出空 = ✅ |

## 六、只在 DEBUG 编译产物里

| # | 动作 | 预期 | 通过判定 |
|---|---|---|---|
| 13 | 终端执行 `grep -c '^#if DEBUG' "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr5a/db-fixtures/ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift"` | 输出 `1` | 输出 `1` = ✅ |
| 14 | 终端执行 `grep -c '^#if DEBUG' "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr5a/db-fixtures/ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/PreviewTrainingSetReader.swift"` | 输出 `1` | 输出 `1` = ✅ |
| 15 | 终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr5a/db-fixtures" && swift build --package-path ios/Contracts -c release 2>&1 \| tail -3` | 输出含 `Build complete!`，无 fake 类型暴露 release | 看到 `Build complete!` = ✅ |

## 失败兜底
任何步骤通过条件不满足，**不要继续合并** —— 把终端完整输出贴给 Claude 让它修。
