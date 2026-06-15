# 验收清单 — 聚合感知 reveal（进行中聚合 K 线 partial 合成）

**交付物：** `PartialAggregateCandle.synthesize` 纯函数 + `RenderStateBuilder.make` 合成挂钩（base 索引契约 + priceRange 重算）= 消除聚合面板（默认 m60/日线）进行中 K 线未来泄漏。设计经 opus 4.8 xhigh spec-review R1→R2 APPROVE 收敛；计划经 opus 4.8 xhigh plan-review R1 收敛；整体 opus + codex:adversarial-review 收敛。关闭 reveal RFC（PR #113）聚合 HIGH residual。

| # | Action | Expected | Pass/Fail |
|---|---|---|---|
| 1 | `cd ios/Contracts && swift test 2>&1 \| tail -2` | `1031 tests in 145 suites passed`，`0 failures` | ☐ |
| 2 | `git diff origin/main...HEAD --stat -- ios/` | 改动集 ⊆ {PartialAggregateCandle.swift(新), RenderStateBuilder.swift, PartialAggregateCandleTests.swift(新), RenderStateBuilderTests.swift}；无 .sql/schema/workflow/CONTRACT_VERSION | ☐ |
| 3 | `cd ios/Contracts && swift test --filter allVisibleWithinTick 2>&1 \| tail -2` | PASS（聚合面板跨 tick 所有可见根 endGlobalIndex≤tick，无未来） | ☐ |
| 4 | `grep -n "PartialAggregateCandle.synthesize" ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift; echo rc=$?` | 命中 `rc=0`（合成挂钩已落地） | ☐ |
| 5 | Mac Catalyst CI：PR checks 页查 `Mac Catalyst build-for-testing on macos-15` | SUCCESS | ☐ |
| 6 | app-target CI：PR checks 页查 app build required check | SUCCESS | ☐ |

## 运行时 runbook（user device/sim 执行）

| # | Action（iPad mini 7 或 Catalyst） | Expected | Pass/Fail |
|---|---|---|---|
| R1 | 训练中观察**非推进面板**（如按下区推进时看上区 m60） | 最新一根聚合 K 线"正在形成"（随每步长高/变体），**不**提前显示完整未来形态 | ☐ |
| R2 | 训练开局聚合面板 | 进行中根即有 partial 实体（**非空白**） | ☐ |
| R3 | 进行中聚合根 | **无** MA66/BOLL/MACD 点（指标线终止在上一根已完成根） | ☐ |
| R4（cosmetic） | 某根聚合 K 线走完瞬间 | 肉眼无明显 OHLC / 量柱跳变（真实数据一致性；spec D6） | ☐ |

## Residuals
- 关闭 reveal RFC（PR #113）聚合 HIGH residual：本 RFC 已根治。
- D6 完成跳变：vendor 各周期独立源，理论一帧轻微 OHLC/量变化（真实数据 close 连续，因当前价=m3 close）；列 R4 device 验收。
