# 验收清单 — persistence-scope 校验（R4 真修：reader+make datetime/聚合窗口边界）

## 自动化校验（命令行可执行）

| # | Action | Expected | Pass/Fail |
|---|---|---|---|
| 1 | `cd ios/Contracts && swift test 2>&1 \| tail -2` | `1048 tests` 全过，`0 failures`（N=基线+10） | ☐ |
| 2 | `git diff origin/main...HEAD --stat -- ios/ docs/` | 改动集 ⊆ {DefaultTrainingSetReader.swift, DefaultTrainingSetReaderTests.swift, PreviewTrainingSetReader.swift, PreviewTrainingSetReaderTests.swift, TrainingEngine.swift, TrainingEngineCoreTests.swift, 本 spec/plan/acceptance}；无 .sql/schema/workflow/CONTRACT_VERSION 改动 | ☐ |
| 3 | `cd ios/Contracts && swift test --filter "test_loadAllCandles_m3DatetimeDescending\|test_loadAllCandles_m3DatetimeDuplicate" 2>&1 \| tail -2` | 两条均 PASS（m3 datetime 非单调被拒 .dbCorrupted） | ☐ |
| 4 | `cd ios/Contracts && swift test --filter "test_loadAllCandles_aggregateOpenPastWindowEnd\|test_loadAllCandles_aggregateFutureOverflow" 2>&1 \| tail -2` | 两条均 PASS（聚合 open 越窗被拒 .dbCorrupted） | ☐ |
| 5 | `cd ios/Contracts && swift test --filter "test_loadAllCandles_preWindowAggregate" 2>&1 \| tail -2` | PASS（pre-window 聚合 load 成功，R1-H1 不回归） | ☐ |
| 6 | `cd ios/Contracts && swift test --filter "makeThrowsOnNonMonotonicM3Datetime" 2>&1 \| tail -2` | PASS（make 纵深防御拒 .emptyData） | ☐ |
| 7 | `grep -nc "isStrictlyIncreasingM3Datetime" ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` | 输出 `2`（helper 定义 + make 调用各 1） | ☐ |
| 8 | `cd ios/Contracts && swift test --filter "m3DatetimeMustStrictlyIncrease\|aggregateOpenMustBeWithinWindow\|preWindowAggregatePasses" 2>&1 \| tail -2` | 三条均 PASS（preview reader 镜像两项校验 + R1-H1 不回归，维护契约不漂移） | ☐ |
| 9 | PR checks 页查 `Mac Catalyst build-for-testing on macos-15` | SUCCESS | ☐ |
| 10 | PR checks 页查 app build required check | SUCCESS | ☐ |

## Residuals
- R-A：DefaultTrainingSetDataVerifier（warmup/content 计数）仍仅在下载验收路径跑，未接 load 路径（内容策略，另案）。
- R-B：聚合周期 datetime 整体单调未校验；唯一消费者 CrosshairLayout 时间轴标签（显示用，乱序仅错标签非泄漏）。
- R-C：reader 内容校验失败经内层 catch 上抛、不自动 cache.delete+重试（既有行为，本 RFC 不改）。

> 说明：表中每行「Expected」均为二元可判定值，避免「验证通过即可 / 看起来正常 / 应该没问题 / should work / looks fine」。
