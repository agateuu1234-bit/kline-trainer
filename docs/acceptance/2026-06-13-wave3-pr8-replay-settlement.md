# 验收清单 — Wave 3 顺位 8：Replay 结算窗（UI/routing-only）

**交付物：** replay 局结束（手动「结束本局」或 auto 抵 maxTick）触发**非持久化**结算窗：消费顺位 6b 冻结的 `coordinator.replaySettlementPayload`，经 `AppRouter.presentReplaySettlement` 设 `.settlement` modal → `SettlementView` 呈现 → 确认路由回首页。**不写 `training_records`、不触 `pending_training`、不改 `finalize`、不自改 E5/E6 契约**（RFC §4.4e/§4.5）。

**前置：** 在 `ios/Contracts` 目录执行命令；macOS 装 Swift 6 工具链。

| # | 操作（action） | 预期（expected） | 通过/不通过（pass/fail） |
|---|---|---|---|
| 1 | `swift test --filter replaySettlementRecord` | `Test run with 2 tests ... 0 failures`；`replaySettlementRecord_replay_returnsPayload`、`replaySettlementRecord_normal_throws` 均 ✔ | 2 tests 且 0 failures 且 2 名 ✔ = 通过 |
| 2 | `swift test --filter presentReplaySettlement` | `Test run with 2 tests ... 0 failures`；`presentReplaySettlement_showsModalNoPersist`（modal=.settlement + records/pending 不变）、`presentReplaySettlement_confirmTearsDown`（confirm 后 reader 关 + nil + 不持久）均 ✔ | 2 tests 且 0 failures 且 2 名 ✔ = 通过 |
| 3 | `swift test`（全量回归） | `Test run with N tests`，`N == 921`（baseline 917 + 新增 4），`0 failures` | N==921 且 0 failures = 通过 |
| 4 | 阅读 `git diff origin/main -- ios/Contracts/Sources` | 仅改 `TrainingSessionLifecycle.swift`（+`replaySettlementRecord`）、`AppRouter.swift`（+`presentReplaySettlement`+注释）、`TrainingView.swift`（+`onReplaySettlement`+`routeEndOfSession`+头注释）、`AppRootView.swift`（+接线 1 行）；**无 `.sql`/schema/`CONTRACT_VERSION` 改动**；**`finalize`/`replaySettlementPayload` 方法体零改动**；无 `TrainingEngine`/render 改动 | 改动文件集 ⊆ {上述 4} 且 finalize/payload 未改 且无 schema/engine 改动 = 通过 |
| 5 | 阅读 `AppRouter.presentReplaySettlement` 方法体 | 仅 `activeModal = .settlement(record)` 一行（不调 insertRecord/savePending/finalize） | 方法体仅设 modal = 通过 |
| 6 | Mac Catalyst CI（PR 上 `Mac Catalyst build-for-testing on macos-15`） | required check 状态 = success | check = success = 通过 |
| 7 | 运行时验收 runbook `docs/runbooks/2026-06-13-wave3-pr8-replay-settlement-runtime-acceptance.md` 存在且含 replay 结算窗 + 不入账断言 | 文件在 PR 文件列表，含「不入账/统计不变」断言项 | 存在且含该断言 = 通过 |

**说明（非破坏性核实）：** 本锚为 UI/routing-only，engine/coordinator payload 逻辑由顺位 6b（PR #97）交付并冻结，本锚不复制不修改其逻辑；非持久化不变量在 6b 已有 `replaySettlementPayload_doesNotPersist` 覆盖，本锚补 router 层 present→confirm 全路径不持久断言（step 2）。
