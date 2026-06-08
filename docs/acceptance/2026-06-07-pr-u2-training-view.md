# PR U2 TrainingView + E6 生命周期接线 验收清单

> 非编码者可执行。每项 action / expected / pass-fail，二值判定。机器验收（swift test）+ 手动运行时（见 runbook）。

## 一、host 单元（机器执行）

> 前置：终端先 `cd ios/Contracts`（本节各行沿用此目录）。

| # | action | expected | pass/fail |
|---|---|---|---|
| 1 | `swift test --filter TrainingSessionLifecycle` | 12 测试全 passed，0 failure | pass = 终端打印 `12 tests ... passed` 且 0 failure |
| 2 | `swift test --filter TrainingTopBarContent` | 8 测试全 passed，0 failure | pass = 终端打印 `8 tests ... passed` 且 0 failure |
| 3 | `swift test` 全量 | `757 tests ... passed`（737 基线 + 20 新），0 failure | pass = 全量 0 failure |

## 二、生命周期 5 路径矩阵（host 测断言，逐条对应）

| # | 路径 | expected | pass/fail |
|---|---|---|---|
| 4 | back（Normal） | pending 写入 + activeEngine/activeReader 清空 | pass = `back_normal_savesAndEnds` 过 |
| 5 | back（Review/Replay） | pending **不**写（非保存分支）+ activeEngine/activeReader 清空 | pass = `back_review_noSaveButEnds`/`back_replay_noSaveButEnds` 过 |
| 6 | auto-end（Normal） | isAtEnd true + finalize 返 recordId + record 入账 + pending 清 | pass = `autoEnd_normal_finalizesAndReturnsId` 过 |
| 7 | auto-end（Review/Replay） | finalize 返 nil + 不入账 | pass = `autoEnd_review_returnsNil`/`autoEnd_replay_returnsNil` 过 |
| 8 | settlement confirm | endAfterSettlement → activeEngine 清空 | pass = `endAfterSettlement_endsSession` 过 |
| 8b | 自动结算门（shouldAutoFinalize） | Review-at-end→false / Normal-at-end→true / 已结算→false / fresh→false | pass = 4 `shouldAutoFinalize_*` 过 |

## 三、Catalyst 编译闸门（CI 权威）

| # | action | expected | pass/fail |
|---|---|---|---|
| 9 | CI `Mac Catalyst build-for-testing on macos-15` | TEST BUILD SUCCEEDED（TrainingView 壳编译过） | pass = CI job 绿 |

## 四、运行时（手动，见 `docs/runbooks/2026-06-07-u2-gesture-runtime-acceptance.md`）

| # | action | expected | pass/fail |
|---|---|---|---|
| 10 | 按 runbook 6 步操作 | 单/双指/长按手势仲裁、交易标记、Review 隐藏交易、自动结束逐项 pass | pass = runbook 6 行全 pass |

## 五、scope 边界（确认延后项不在本 PR）

| # | action | expected | pass/fail |
|---|---|---|---|
| 11 | `grep -nE "结束本局|画线|仓位 X/5|forceClose" ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`（注：`-E` 下用裸 `|` 交替，勿写 `\|`，否则匹配字面竖线致假阳性） | 仅命中注释里的延后说明（D7/D8 的「画线」「仓位 X/5」），无对应功能代码 | pass = 命中仅注释行、无延后项功能代码 |

## 六、延后项（residual，本 PR 不交付，文档化上交）

- **U2-R1**：手动「结束本局」按钮（含强平）—— 需 frozen E5 无的手动强平方法，归后续/Wave 3。
- **U2-R2**：画线工具面板 —— 画线输入 DrawingInputController 属 Wave 3。
- **U2-R3**：顶栏「仓位 X/5」—— PositionManager 无档位存值 + 项目拒绝臆造 tier 公式。
- **U2-R4**：`SettlementView` 呈现 + record 加载 —— 归顺位 11 组合根（路由+repo owner）；U2 经 `onSessionEnded(recordId:)` 上交。
