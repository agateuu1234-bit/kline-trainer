# Wave 3 顺位 7 — U2 交易 UI（仓位 X/5 + 手动强平 + Toast/触觉）运行时验收 runbook

**性质**：device/simulator **手动**验收（CI 仅 Catalyst 编译守护，不验运行时触觉/Toast/路由）。
执行者：user（操作 + 记录），非编码者可执行。每项 action / expected / pass-fail。

> 前置：经顺位 10 全 app fixture provisioning（顺位 7 实施时若未落地，则用 DEBUG `.preview()` 或已有缓存训练组），
> 在 iPhone/iPad 启动 `KlineTrainer` app target，进入一局 **Normal** 训练。

| # | action | expected | pass/fail |
|---|---|---|---|
| 1 | 空仓时看顶栏「仓位」 | 显示「仓位 0/5」 | pass = 0/5 |
| 2 | 买入 3/5（点买入 → 选 3/5） | (a) 触发一次 **.heavy 触觉**；(b) 顶栏「仓位」即时变为约「3/5」（容 round ±1 档）；(c) 顶栏总资金 = 实时（现金+持仓市值，§4.2） | pass = 触觉 + 仓位更新 + 总资金实时 |
| 3 | 满仓后（5/5）再点买入 | 买入按钮**灰置不可点**（不弹 HUD、无 Toast、无触觉） | pass = 按钮 disabled |
| 4 | 构造资金不足档位买入（若可点到使股数取整为 0 的档） | 弹 **Toast「可用资金不足」**；**无触觉**；持仓/资金/tick **不变**（失败不 mutate） | pass = Toast 可见 + 不震动 + 状态不变 |
| 5 | 空仓点卖出 | 卖出按钮**灰置不可点** | pass = 按钮 disabled |
| 6 | 卖出成功 | 触发 **.heavy 触觉**；仓位档位下降；总资金实时更新 | pass = 触觉 + 仓位降 |
| 7 | 点底部左侧「结束本局」→ 弹确认「结束本局训练」→ 点「否」 | 对话框消失；**仍在本局**（无强平、无结算、状态不变） | pass = 取消不路由 |
| 8 | 再点「结束本局」→「是」（有持仓） | 若有持仓按当前收盘价强制平仓 → 弹 **结算窗**（显示 total_capital 冻结值）→ 确认回首页，按钮变「继续训练」消失（已入账） | pass = 强平 + 结算 + 入账 |
| 9 | Replay 模式重复 step 8 | 手动结束触发（本顺位 7 replay 仍走 retreat 回首页，**不**显示结算窗——结算窗归顺位 8）；记录数/统计**不变** | pass = retreat + 不入账（顺位 8 再补结算窗） |
| 10 | Review 模式看底部 | **无「结束本局」按钮**（capability matrix「结束按钮 Review ❌」，用返回退出）；无交易按钮 | pass = 无结束/交易按钮 |

**回填**：执行后逐行填 pass/fail。本 runbook 作 Wave 3 新交互运行时矩阵一项，是顺位 13 收尾阻塞依赖之一（spec §三.3）。
失败可见性（step 4）+ 触觉（step 2/6）+ 手动结束路由（step 8）是本顺位核心运行时断言。
