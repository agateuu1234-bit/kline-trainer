# U2 手势仲裁运行时验收 runbook（C7 单指 pan / 两指周期切换 / 长按十字光标）

**性质**：device/simulator **手动**验收（CLI/CI 仅编译，不跑 UIKit 运行时；per outline §四 L121）。
执行者：user（按步骤操作 + 记录），非编码者可执行。每项 action / expected / pass-fail。

> 前置：在 iPad / Mac Catalyst 运行含 `TrainingView(lifecycle:onExit:onSessionEnded:)` 的宿主
> （顺位 11 组合根，或最小 SwiftUI 宿主用 `TrainingSessionLifecycle(engine: .preview(mode: .normal), coordinator: .preview())`）。
> **步骤 5 验 Review 模式**：须改用 `.preview(mode: .review)` 启动宿主（交易按钮组应隐藏）。
> 本 runbook 验 C7 手势仲裁运行时；C2 减速 + C8 帧预算见 `2026-06-07-c8b-runtime-acceptance.md`。
>
> **注（独立 preview 宿主）**：最小 preview 宿主用两个**独立** `.preview()`（engine 非 coordinator 的活跃 engine）
> → 抵末态调 `finalize` 会因「无活跃 session 上下文」抛错，View 的 catch 触发 `onSessionEnded(nil)`。故独立
> preview 仅验「触发器/onSessionEnded 上交」路径；真实「finalize 入账」须用顺位 11 接线后的活跃-session 宿主。
> 手势仲裁（步骤 1-3）不受影响，preview 宿主可完整验。

| # | action | expected | pass/fail |
|---|---|---|---|
| 1 | 单指水平拖动上区 K 线 | 图表随手指水平滚动（pan 截获）；单指不触发周期切换/缩放（惯性减速归 c8b runbook 步骤 1，本表只验 C7 截获） | pass = 跟手水平滚动且 pan 截获、单指不触发周期切换 |
| 2 | 两指上下滑动 | 周期组合切换（上区/下区 period 同步平移一档，如 60m/日→日/周） | pass = 两指滑触发周期切换、单指不触发 |
| 3 | 长按 K 线并拖动 | 出现十字光标随手指移动；松手消失 | pass = 十字光标显示/跟随/消失 |
| 4 | Normal 模式点「买入」选档 → 确认 | 触发交易，所有周期对应 K 线同步出现红点 B 标记 | pass = 标记同步出现 |
| 5 | Review 模式进入训练页 | 交易按钮组隐藏（capability matrix L833 / canBuySell()==false），仅可浏览/十字光标 | pass = 无买卖持有按钮 |
| 6 | 反复步进（持有/观察）至 maxTick | 局自动结束（onSessionEnded 触发，宿主呈现结算/返回） | pass = 抵末态自动结束 |

**回填**：执行后逐行填 pass/fail；本 runbook 链接进 Wave 2 收尾 completion doc 作 C7 手势运行时 artifact。
