# 验收清单 — Wave 3 顺位 7：U2 交易 UI 接线 + 交易反馈

**交付物：** 顶栏「仓位 X/5」+ 底部「结束本局」手动强平（确认弹窗 → 路由结算）+ 交易失败 Toast + 成功 .heavy 触觉。
纯值层 `TradeFeedback` + `TrainingTopBarContent.position`（host 测）；`TrainingView` 壳接线（Catalyst 编译守护）。
engine/schema/持久化 **0 改动**（6a + RFC 契约消费）。

**前置：** 在 `ios/Contracts` 目录执行命令；macOS 装 Swift 6 工具链。

| # | 操作（action） | 预期（expected） | 通过/不通过（pass/fail） |
|---|---|---|---|
| 1 | `swift test --filter TradeFeedback` | `Test run with 6 tests ... 0 failures`；6 个 TradeFeedback 测试全 ✔（成功触觉 / 资金不足·持仓不足·股数非法 Toast / disabled 抑制） | 6 ✔ 且 0 failures = 通过 |
| 2 | `swift test --filter TrainingTopBar` | 既有 currency/percent 测试 + 3 个新「仓位 X/5」测试（0/5、3/5、5/5）全 ✔，`0 failures`（共 11 tests in 2 suites） | 全 ✔ 且 0 failures = 通过 |
| 3 | `swift test`（全量回归） | `Test run with 917 tests`（基线 908 + 新增 9），`0 failures` | 917 且 0 failures = 通过 |
| 4 | 阅读 `git diff origin/main -- ios/Contracts/Sources` | 仅 `TradeFeedback.swift`（新）、`TrainingTopBarContent.swift`、`TrainingView.swift` 被改；**无** `TrainingEngine.swift` / `*.sql` / schema / `CONTRACT_VERSION` / coordinator 改动 | 改动文件集 ⊆ {TradeFeedback, TrainingTopBarContent, TrainingView} 且无 engine/schema = 通过 |
| 5 | 阅读 `TrainingView.swift` topBar | `TrainingTopBarContent(...)` 第一参数仍为 `engine.currentTotalCapital`（§4.2 实时总资金未回归）；新增 `positionTier: engine.currentPositionTier` | 总资金参数 = currentTotalCapital 且 tier 接 currentPositionTier = 通过 |
| 6 | Mac Catalyst CI（PR 上 `Mac Catalyst build-for-testing on macos-15`） | required check 状态 = success（壳 UIImpactFeedbackGenerator/confirmationDialog/overlay 编译链接通过） | check = success = 通过 |
| 7 | 运行时 runbook（`docs/runbooks/2026-06-13-wave3-pr7-trade-ui-runtime-acceptance.md`） | user 在 device/sim 逐行执行回填 pass（仓位实时 / Toast 可见 / 触觉 / 手动结束→结算 / 失败不 mutate） | 10 行 runbook 回填 = 顺位 13 阻塞项（本 PR 交付 runbook 文件即可，实测回填随运行时矩阵） |

**证据上传：** PR comment 附命令 #1–#3 尾部输出（含 `Test run with ... 0 failures`）+ #4 diff 文件清单 + CI check 链接。
