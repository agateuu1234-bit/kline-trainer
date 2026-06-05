# 验收清单 — E5a TrainingEngine 核心（Wave 2 顺位 2）

> 语言：中文；判定二元可决。本模块是「训练引擎运行时核心」：把一局训练的实时状态
> （现金、持仓、标记、画线、双周期面板）装进一个可观测对象，并对外提供总资金、收益率、
> 持仓成本、最大回撤等只读数值（买卖按钮可用性属 E5b）。**本机 Linux 无 swift**，标注 [CI] 的行
> 在 GitHub Actions（macos-15）执行，不可在本机谎称通过。

## 一、自动闸门（命令可机器核验）

| # | 动作 | 期望 | 通过 |
|---|---|---|---|
| 1 | `bash scripts/acceptance/plan_e5a_trainingengine_core.sh; echo exit=$?` | 末行 `=== ALL E5a ACCEPTANCE CHECKS PASSED ===`，`exit=0` | ☐ |
| 2 | [CI] `cd ios/Contracts && swift build` | `Build complete!` | ☐ |
| 3 | [CI] `cd ios/Contracts && swift test --filter TrainingEngineCoreTests` | `0 failures`，全部 @Test 绿 | ☐ |
| 4 | [CI] `cd ios/Contracts && swift test` | 全量 `0 failures`（无回归） | ☐ |
| 5 | [CI Catalyst 必绿闸门] `xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/e5a-catalyst` | `** TEST BUILD SUCCEEDED **`（required check `Mac Catalyst build-for-testing on macos-15`，不可 bypass） | ☐ |

## 二、业务规则验收（映射到具名测试）

| # | 规则 | 验证测试 | 期望 | 通过 |
|---|---|---|---|---|
| 6 | init 接线：现金/初始资金/空仓/起始 tick/初始组合 60m+日线 | `initWiresRuntimeState` | PASS | ☐ |
| 7 | drawdown seeding + 反映当前回撤：fresh→peak=起始总资金/dd=0、带仓含市值、resume→peak 取 max 且 maxDD 纠正为当前回撤（R2-F1 + R5-F1） | `freshSessionSeedsDrawdownPeakFromStartingCapital` / `freshSessionSeedPeakIncludesInitialPositionValue` / `resumeReconcilesDrawdownToCurrentTotal` | PASS | ☐ |
| 8 | 总资金 = 现金 + 持仓市值（现价取 `.m3` 驱动序列收盘价） | `currentTotalCapitalAddsMarketValueAtCurrentPrice` | PASS | ☐ |
| 9 | 现价只取 `.m3`、不取聚合周期未来价（R4-F2） | `currentPriceUsesM3DrivingSeriesNotAggregate` | PASS | ☐ |
| 10 | 收益率 = (总资金−初始资金)/初始资金 | `returnRateIsNetRatioOverInitialCapital` | PASS | ☐ |
| 11 | maxDrawdown = 非负绝对额（元），非比率（E6 换算） | `maxDrawdownIsAbsoluteAmountPerSpec` | PASS | ☐ |
| 12 | review 起于末态 tick；flow/maxTick 契约边界（R4-F1） | `reviewModeStartsAtFinalTick` | PASS | ☐ |
| 13 | 场景中继不改业务状态 | `onSceneActivatedIsSafeAndPure` | PASS | ☐ |
| 14 | preview 三模式可构造 + maxTick 匹配 fixture + period==key + 默认面板(.m60/.daily)有数据（R3-F2/R4-F3/R5-F2） | `previewBuildsAllModes` / `previewMaxTickMatchesFixtureRange` / `previewFixtureCandlePeriodsMatchKeys` / `previewProvidesCandlesForDefaultPanels` | PASS | ☐ |
| 15 | resume：从保存 tick 起算、现价用该 tick；m3 覆盖 maxTick（R6-F1/R6-F2） | `resumeNormalModeUsesSavedTickForPrice` | PASS | ☐ |
| 16 | drawdown peak ≥ 声明 initialCapital 基线（R6-F3） | `drawdownSeedsAtLeastDeclaredInitialCapital` | PASS | ☐ |
| 17 | resume 恢复保存的周期组合（R6） | `resumeRestoresSavedPanelCombo` | PASS | ☐ |

## 三、流程合规与偏差

| # | 项 | 期望 | 通过 |
|---|---|---|---|
| 18 | 作用域守卫：G8 无 E5b 动作 + G4 无 buy/sellEnabled + G2b 含 R4-R6 前置（flow/maxTick、`.m3` 驱动+覆盖、resume tick、drawdown 基线、无 finestPeriod） | grep 命中/不命中均如期 | ☐ |
| 19 | codex 对抗性评审 branch-diff | verdict `approve`（收敛） | ☐ |
| 20 | 契约登记：D3 E6 换算契约；D4 buy/sellEnabled 移 E5b；D5/D7 init 签名 additive 扩展（resume tick + 周期组合）待 E6 RFC 确认 | PR body 已列 | ☐ |

**任一条 ✗ → 不得 merge。**
