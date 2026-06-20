# 验收清单：买卖小操作栏（内联展开 + 全仓/清仓快捷）（RFC #1）

## 1. host 单测（机器执行）
- [ ] 动作：`cd ios/Contracts && swift test --filter TradeBarContentTests`
      预期：`TradeBarContent host tests` 9 个全绿。
- [ ] 动作：`cd ios/Contracts && swift test`
      预期：全量 0 failures，相对基线净 = +TradeBarContent(9) −PositionPickerContent(10)。

## 2. Mac Catalyst 编译（机器执行）
- [ ] 动作：`xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst'`
      预期：`** TEST BUILD SUCCEEDED **`。

## 3. iOS app build（机器执行）
- [ ] 动作：`xcodebuild build -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/app-derived CODE_SIGNING_ALLOWED=NO`（同 app-build.yml；若报 SwiftPM 包依赖未解析，改 `-workspace ios/KlineTrainer/KlineTrainer.xcodeproj/project.xcworkspace`）
      预期：`** BUILD SUCCEEDED **`。

## 4. 模拟器人工验收（非编码者执行，iPhone 17 Pro 模拟器 + seed fixture）
| # | 动作 | 预期 | 通过? |
|---|---|---|---|
| 1 | 进训练，点上面板「买入」 | 该面板底部悬浮出现横排小条 `[1/5][2/5][3/5][4/5][全仓] ✕`，无模态弹窗 | ☐ |
| 2 | 点小条某分档（如 2/5） | 立即按 2/5 买入成交（触觉+标记），小条收起 | ☐ |
| 3 | 再点「买入」，点末档「全仓」 | 按全仓（tier5）买入成交，小条收起 | ☐ |
| 4 | 全仓档视觉 | 「全仓」chip 为强调色（与 1/5–4/5 区分） | ☐ |
| 5 | 有持仓时点「卖出」 | 小条末档显示「清仓」（非「全仓」），点清仓全部卖出 | ☐ |
| 6 | 点小条 ✕ | 小条收起，不成交、不推进 | ☐ |
| 7 | 点上面板「买入」后再点下面板「卖出」 | 同时只有一个小条（上面板小条消失、下面板出现卖出小条） | ☐ |
| 8 | 进复盘(Review)模式 | 右列买卖按钮与小条均不显示（能力矩阵不变） | ☐ |
| 9 | 空仓时看「卖出」按钮 | 灰置不可点（sellEnabled=false，无法打开清仓小条） | ☐ |

## 5. 回归确认（非编码者执行）
| # | 动作 | 预期 | 通过? |
|---|---|---|---|
| 1 | 买入/卖出成交 | 触觉(.heavy)+红B/绿S 标记+推进 K 线，一切如常（performTrade 体不变） | ☐ |
| 2 | 资金不足点全仓 | 出 toast 失败提示（TradeFeedback 路径不变） | ☐ |
| 3 | 图表 pan/pinch/坐标轴 | 滚动/缩放/RFC #3 轴网格一切如常（overlay 不扰图表几何） | ☐ |

## 6. Opus 4.8 xhigh 对抗性 review ledger（代 codex，user explicit）
- spec：R1 NEEDS-ATTENTION（C1+2H+2M+3L）→ 全修 → R2（2 引用精度）→ 收敛 APPROVE。commits 397a40b / aa03c94 / a07ba09。
- plan：（实施前 review 回填）。
- 实现期（subagent-driven）：（回填）。
- branch-diff：（回填）。
