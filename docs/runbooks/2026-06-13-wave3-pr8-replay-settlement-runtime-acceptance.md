# Wave 3 顺位 8 — Replay 结算窗运行时验收 runbook

**性质**：device/simulator **手动**验收（CI 仅 Catalyst 编译守护，不验运行时路由/呈现/持久化副作用）。
执行者：user（操作 + 记录），非编码者可执行。每项 action / expected / pass-fail。

> 前置：经顺位 10 全 app fixture provisioning（若未落地则用已有缓存训练组 + 已有一条历史记录），
> 在 iPhone/iPad 启动 `KlineTrainer` app target；从首页对一条历史记录选「再来一次」进入一局 **Replay** 训练。
> 记录验收前先看首页：记录条数 + 胜率/总资金统计，作为「不入账」基线。

| # | action | expected | pass/fail |
|---|---|---|---|
| 1 | Replay 局中点底部左侧「结束本局」→ 弹确认「结束本局训练」→ 点「否」 | 对话框消失；**仍在本局**（无强平、无结算、状态不变） | pass = 取消不路由 |
| 2 | 再点「结束本局」→「是」（有持仓） | 有持仓按当前收盘价强制平仓 → **弹结算窗**（显示 total_capital 冻结值 / 总收益率 / 最大回撤 / 买卖次数，§4.2 口径） | pass = 强平 + 结算窗弹出 |
| 3 | 结算窗点「确认」 | 结算窗关闭 → 回首页 | pass = 回首页 |
| 4 | 回首页后对比基线统计 | **记录条数不变 + 胜率/总资金统计不变**（replay 不入账、不计入统计，RFC §4.5） | pass = 统计完全不变 |
| 5 | 再进同一记录的 Replay，步进/持有直到 **auto 抵 maxTick**（不手动结束） | 抵末态自动强平 → **自动弹结算窗**（同 step 2 内容）→ 确认回首页 | pass = auto 末态也弹结算窗 |
| 6 | step 5 确认回首页后看统计 | 记录条数 + 统计仍**不变**（auto replay 同样不入账） | pass = 统计不变 |
| 7 | （对照）Normal 局结束 → 结算窗 → 确认 | 结算窗显示 + 确认后**记录条数 +1**（Normal 入账，与 replay 区分） | pass = Normal 入账（证 replay 非误抑制持久化） |

**回填**：执行后逐行填 pass/fail。本 runbook 作 Wave 3 新交互运行时矩阵一项，是顺位 13 收尾阻塞依赖之一（spec §三.3）。
核心运行时断言 = replay 结算窗呈现（step 2/5）+ **不入账/统计不变**（step 4/6，区别于 Normal step 7）。
