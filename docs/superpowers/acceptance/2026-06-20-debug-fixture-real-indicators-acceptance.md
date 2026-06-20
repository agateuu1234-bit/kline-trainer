# 验收清单：丰富 DEBUG fixture（真实感 OHLCV + MA66/BOLL/MACD）

PR：丰富 debug fixture 真实指标 ·分支 `feat/debug-fixture-real-indicators`

## §1 自动化门（CI / host 已覆盖，此处复述结论）
| 动作 | 预期 | 通过/否决 |
|---|---|---|
| `cd ios/Contracts && swift test` | 约 1146 tests / 0 fail（含 FixtureIndicatorMath 7 + FixturePriceSeries 8 + DebugFixtureData 11 + Writer 2） | ☐ |
| Mac Catalyst `build-for-testing` | TEST BUILD SUCCEEDED | ☐ |
| iOS app build | BUILD SUCCEEDED | ☐ |

## §2 人工模拟器验收（运行时观感，自动化测不到）
前置：iPhone 模拟器装 iOS runtime，`SIMCTL_CHILD_KLINE_SEED_FIXTURE=1 xcrun simctl launch ... <bundle-id>` 注入 seed，进入一局训练（默认上区 60 分 / 下区 日线）。

| # | 动作 | 预期 | 通过/否决 |
|---|---|---|---|
| 1 | 看上区主图（60 分） | 见 MA66 一条平滑均线 + BOLL 三轨（上/中/下带），带宽有收有张（非三线重叠、非缺线） | ☐ |
| 2 | 看下区主图（日线） | 同样见 MA66 + BOLL 三轨，与上区独立 | ☐ |
| 3 | 看任一区 MACD 副图 | 见红/绿 MACD 柱穿越零轴 + DIF/DEA 两条线（非空白、非全平） | ☐ |
| 4 | 看 K 线形态 | 实体/影线有真实变化（涨跌不一），非平滑等幅正弦波 | ☐ |
| 5 | 切换周期 combo（上区/下区周期换档） | 每个周期都有 MA66/BOLL/MACD（满载下 monthly 末段亦有 MA66） | ☐ |
| 6 | 横向拖动看历史段 | 指标随蜡烛连续，无突兀断线（暖机段 MA66/BOLL 前缀留空属正常） | ☐ |

## §3 回归（不应改变的行为）
| 动作 | 预期 | 通过/否决 |
|---|---|---|
| 买卖/结算/历史弹窗/pan 联动 | 与本 PR 前一致（本 PR 仅改 DEBUG fixture 数据，零生产代码） | ☐ |
| Release 构建 | fixture 代码整体 `#if DEBUG` 剔除，无体积/行为影响 | ☐ |
