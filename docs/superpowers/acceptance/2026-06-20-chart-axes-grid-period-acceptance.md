# 验收清单：图表坐标轴 / 网格 / 周期标注（RFC #3）

## 1. host 单测（机器执行）
- [ ] 动作：`cd ios/Contracts && swift test --filter AxisGridLayout`
      预期：`AxisGridLayout` 各 Suite 全绿（PriceTicks/TimeTicks/VolumeMacd/PeriodLabel/Resolve）。
- [ ] 动作：`cd ios/Contracts && swift test`
      预期：全量通过，0 failures，相对基线无回归。

## 2. Mac Catalyst 编译（机器执行）
- [ ] 动作：`xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst'`
      预期：`** TEST BUILD SUCCEEDED **`。

## 3. iOS app build（机器执行）
- [ ] 动作：构建 app target（按仓库现有 app build 命令/CI job）。
      预期：`** BUILD SUCCEEDED **`。

## 4. 模拟器人工验收（非编码者执行，iPhone 17 Pro 模拟器 + seed fixture）
| # | 动作 | 预期 | 通过? |
|---|---|---|---|
| 1 | 启动训练，看上面板（默认 60 分） | 右缘有整齐价格刻度数字、对齐的横向网格线 | ☐ |
| 2 | 看上面板左上角 | 显示「60分」角标 | ☐ |
| 3 | 看屏幕底部 | 一条时间轴，分钟级显示「MM-DD HH:mm」格式 | ☐ |
| 4 | 看量图区 | 顶部有最大量标签（万/亿），一条水平网格 | ☐ |
| 5 | 看 MACD 区 | 有一条 0 轴水平线 + 「0」标签 | ☐ |
| 6 | 看下面板（默认日线） | 角标「日」，时间轴显示「YYYY-MM-DD」格式 | ☐ |
| 7 | 两指上滑切到更大周期（如月线） | 角标与时间轴格式随周期变化（月线「YYYY-MM」） | ☐ |
| 8 | 切到暗/亮主题 | 网格线 gridLine 在两主题下都可见、不刺眼 | ☐ |
| 9 | 长按出十字光标 | 十字光标 HUD 盖在坐标轴标签之上（层序正确） | ☐ |

## 5. 回归确认（非编码者执行）
| # | 动作 | 预期 | 通过? |
|---|---|---|---|
| 1 | 买入/卖出/平仓 | 交易动作与标记一切如常（未受渲染改动影响） | ☐ |
| 2 | pan/pinch/复盘 | 滚动、缩放、复盘出图一切如常 | ☐ |

## 6. Opus 4.8 xhigh 对抗性 review ledger（代 codex，user explicit）
- spec：R1 NEEDS-ATTENTION（3H/2M）→ 全修 → R2 APPROVE（+3L 修）。commits 5f15d68 / 74b397b。
- plan：R1 APPROVE（+3L 修）。
- branch-diff：<填 branch-diff 结论>。
