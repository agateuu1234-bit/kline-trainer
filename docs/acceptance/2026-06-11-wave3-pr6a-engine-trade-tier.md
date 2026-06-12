# 验收清单 — Wave 3 顺位 6a：TrainingEngine 交易/档位 engine 契约扩展

**交付物：** `forceCloseManually()`（RFC §4.4a 手动强平）+ `currentPositionTier`（RFC §4.4b/§4.1 当前持仓档位 X/5）两个 engine API。纯逻辑层增量，无 UI、无 schema、无持久化改动。

**前置：** 在 `ios/Contracts` 目录执行命令；macOS 装 Swift 6 工具链。

| # | 操作（action） | 预期（expected） | 通过/不通过（pass/fail） |
|---|---|---|---|
| 1 | `swift test --filter currentPositionTier` | 输出含 `Test run with` 行且 `0 failures`；6 个 `currentPositionTier*` 测试全 ✔（含 `currentPositionTierZeroOnNonFiniteOverflow` 溢出守卫） | 全 ✔ 且 0 failures = 通过；任一 ✘ 或非零 failures = 不通过 |
| 2 | `swift test --filter forceClose` | 16 个新测试全 ✔（含 `NoOpOnFiniteOverflowPrice`/`NoOpOnCashSumOverflow` 现金不被写 NaN/inf、`ReturnsFalseWhenDrawdownNonFinite`/`ReturnsFalseWhenReturnRateNonFinite`/`ReturnsFalseWhenLiquidationGoesNegative` 安全降级、`autoForceCloseNoOpOnCashSumOverflow`）；既有 4 个 auto 强平测试仍 ✔ | 全 ✔ 且 0 failures = 通过；否则不通过 |
| 3 | `swift test --filter forceClose`（含既有局终自动强平） | 既有 `advancingToEndWithHoldingForceCloses` 仍 ✔（其 `maxDrawdown == 10` 断言证抽 `performForceClose` 共用体未改 auto 强平行为） | 既有强平测试仍 ✔ = 通过；任一既有测试因重构转 ✘ = 不通过 |
| 4 | `swift test`（全量回归） | `Test run with N tests`，`N ≥ 821`（基线 799 + 新增 22），`0 failures` | 0 failures = 通过；≥1 failure = 不通过 |
| 5 | 阅读 `git diff origin/main -- ios/Contracts/Sources` | 仅 `TrainingEngine.swift` 被改；无 `.sql` / 无 schema / 无 `CONTRACT_VERSION` 改动；新增 `currentPositionTier`、`forceCloseManually`、`isSettlementSafe`、`performForceClose` 符号（`forceCloseIfEnded` 改为调用 `performForceClose`）；**未改** `reader`/`init`/`advanceAndAccount`/`buy`/`sell`/`TrainingSessionCoordinator` | 改动文件集 = {TrainingEngine.swift} 且无 schema/version 改动且未触 coordinator/reader = 通过；否则不通过 |
| 6 | Mac Catalyst CI（PR 上 `Mac Catalyst build-for-testing on macos-15`） | required check 状态 = success（编译 + 链接通过） | check = success = 通过；failure = 不通过 |

**证据上传：** PR comment 附命令 #1–#4 的尾部输出（含 `Test run with ... 0 failures` 行）+ CI check 截图/链接。
