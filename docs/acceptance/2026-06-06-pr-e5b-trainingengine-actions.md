# 验收清单 — E5b TrainingEngine 交易动作（Wave 2 顺位 3）

> 语言：中文；判定二元可决。本模块给 E5a 运行时核心补全「可操作」能力：买入/卖出/持有观察
> 四个动作 + 买卖按钮可用性门 + 局终自动强平。画线方法（activateDrawingTool/deleteDrawing）
> 延后顺位 7 C8。**本机 Linux 无 swift**，标注 [CI] 的行在 GitHub Actions（macos-15）执行，
> 不可在本机谎称通过。

## 一、自动闸门（命令可机器核验）

| # | 动作 | 期望 | 通过 |
|---|---|---|---|
| 1 | `bash scripts/acceptance/plan_e5b_trainingengine_actions.sh; echo exit=$?` | 末行 `=== ALL E5b ACCEPTANCE CHECKS PASSED ===`，`exit=0` | ☐ |
| 2 | [CI] `cd ios/Contracts && swift build` | `Build complete!` | ☐ |
| 3 | [CI] `cd ios/Contracts && swift test --filter TrainingEngineActionsTests` | `0 failures`，全部 @Test 绿 | ☐ |
| 4 | [CI] `cd ios/Contracts && swift test` | 全量 `0 failures`（无回归） | ☐ |
| 5 | [CI Catalyst 必绿闸门] `xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/e5b-catalyst` | `** TEST BUILD SUCCEEDED **`（required check `Mac Catalyst build-for-testing on macos-15`，不可 bypass） | ☐ |

## 二、业务规则验收（映射到具名测试）

| # | 规则 | 验证测试 | 期望 | 通过 |
|---|---|---|---|---|
| 6 | 买入：当前 tick 价成交、扣现金、加持仓、推进、记 buy marker + operation（entryTick） | `buySuccessDeductsCashAddsPositionAndAdvances` / `buyRecordsBuyMarkerAtEntryTick` | PASS | ☐ |
| 7 | 买入用 entryTick 价（非 advance 后价） | `buyUsesEntryTickPriceNotPostAdvancePrice` | PASS | ☐ |
| 8 | 买入失败（资金不足）不 mutate、不 advance、返 `.trade(.insufficientCash)` | `buyFailureInsufficientCashLeavesStateUnchanged` | PASS | ☐ |
| 9 | review 模式买入返 `.trade(.disabled)` | `buyFailsInReviewModeWithDisabled` | PASS | ☐ |
| 10 | 卖出：加现金（proceeds）、减持仓、印花税>0、tier5 清仓、totalCost=proceeds | `sellSuccessAddsCashReducesPositionAndAdvances` / `sellPartialTierKeepsRemainingShares` | PASS | ☐ |
| 11 | 卖出失败：空仓 `.disabled`、取整为 0 `.insufficientHolding`、review `.disabled` | `sellFailsWhenFlatWithDisabled` / `sellFailsInsufficientHoldingWhenRoundsToZero` / `sellFailsInReviewModeWithDisabled` | PASS | ☐ |
| 12 | 持有/观察：仅推进 tick、无 marker/operation、按点击面板周期步进、更新回撤 | `holdOrObserveAdvancesOneTickSamePeriod` / `holdOrObserveRecordsNoMarkerOrOperation` / `holdOrObserveStepsByClickedPanelPeriod` / `holdOrObserveUpdatesDrawdownAtNewTick` | PASS | ☐ |
| 13 | 持有/观察 review 模式 no-op（canAdvance false） | `holdOrObserveNoopsInReviewMode` | PASS | ☐ |
| 14 | 买卖持观均硬切两面板 autoTracking（plan L235） | `buyHardSwitchesBothPanels` / `holdOrObserveHardSwitchesPanelsToAutoTracking` | PASS | ☐ |
| 15 | 局终强平：到顶有持仓→全平、加 proceeds、记 tier5/.m3/.sell marker+operation（D7） | `advancingToEndWithHoldingForceCloses` | PASS | ☐ |
| 16 | 局终强平：无持仓不触发；幂等（重复到顶不重复平） | `advancingToEndWithoutHoldingDoesNotForceClose` / `forceCloseIsIdempotentAcrossRepeatedEndAdvances` | PASS | ☐ |
| 17 | 买入推进到顶触发强平（buy + 强平两笔 operation） | `buyThatAdvancesToEndTriggersForceClose` | PASS | ☐ |
| 18 | buyEnabled：可买 true / 现金耗尽 false / review false | `buyEnabledTrueWhenAffordable` / `buyEnabledFalseWhenCashExhausted` / `buyEnabledFalseInReviewMode` | PASS | ☐ |
| 19 | sellEnabled：有仓 true / 空仓 false / review false | `sellEnabledTrueWhenHolding` / `sellEnabledFalseWhenFlat` / `sellEnabledFalseInReviewMode` | PASS | ☐ |
| 20 | 周期组合：toLarger/toSmaller 平移、边界 no-op、重置 autoTracking+bump、不 advance、无数据 no-op | `switchToLargerMovesComboUp` / `switchToSmallerMovesComboDown` / `switchToLargerAtTopBoundaryNoops` / `switchToSmallerAtBottomBoundaryNoops` / `switchResetsPanelsToAutoTrackingAndBumpsRevision` / `switchDoesNotAdvanceTick` / `switchNoopsWhenTargetPeriodHasNoData` | PASS | ☐ |

## 三、流程合规与偏差

| # | 项 | 期望 | 通过 |
|---|---|---|---|
| 21 | 作用域守卫：G2 无画线方法（延后顺位 7）+ G4 E5a 面未破坏 | grep 命中/不命中均如期 | ☐ |
| 22 | 偏差登记：D5（createdAt=m3 datetime，非墙钟）/ D8（switchPeriodCombo 数据守卫）/ D9（防御式 ?? []）/ 画线延后顺位 7 | PR body 已列 | ☐ |
| 23 | codex/opus 对抗性评审 branch-diff | verdict `approve`（收敛） | ☐ |
